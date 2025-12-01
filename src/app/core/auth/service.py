"""Authentication service for login, registration, and token management."""

from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import Depends

from app.api.dependencies import DBSession
from app.config import settings
from app.core.auth.backend import (
    create_access_token,
    create_refresh_token,
    get_token_expiration,
    hash_password,
    hash_token,
    verify_password,
)
from app.core.auth.schemas import TokenPair
from app.core.errors import ConflictError, UnauthorizedError
from app.core.utils.text import generate_slug
from app.modules.tenants.models import Tenant
from app.modules.users.models import RefreshToken, User
from app.modules.users.repos import RefreshTokenRepository, UserRepository


class AuthService:
    """Service for authentication operations.

    Handles user registration, login, token refresh, and logout.
    """

    def __init__(self, db: DBSession) -> None:
        self.db = db
        self.user_repo = UserRepository(db)
        self.token_repo = RefreshTokenRepository(db)

    async def register(
        self,
        email: str,
        password: str,
        full_name: str,
        tenant_name: str,
    ) -> tuple[User, TokenPair]:
        """Register a new user and tenant.

        Creates a new tenant and the first user (as superuser).

        Args:
            email: User's email address
            password: Plain text password
            full_name: User's full name
            tenant_name: Name for the new tenant

        Returns:
            Tuple of (user, token_pair)

        Raises:
            ConflictError: If email already exists
        """
        # Check if email already exists globally (P3-1: generic message to prevent enumeration)
        existing = await self.user_repo.get_by_email_system(email)
        if existing:
            raise ConflictError(
                "Registration failed. If this email is already registered, please use the login page.",
                error_code="registration_failed",
            )

        # Create tenant
        tenant = Tenant(
            name=tenant_name,
            slug=generate_slug(tenant_name),
        )
        self.db.add(tenant)
        await self.db.flush()

        # Create user as superuser of the tenant
        user = User(
            email=email,
            password_hash=hash_password(password),
            full_name=full_name,
            tenant_id=tenant.id,
            is_superuser=True,
        )
        user = await self.user_repo.create(user)

        # Generate tokens
        token_pair = await self._create_tokens(user)

        return user, token_pair

    async def login(
        self,
        email: str,
        password: str,
        user_agent: str | None = None,
        ip_address: str | None = None,
    ) -> tuple[User, TokenPair]:
        """Authenticate a user with email and password.

        Args:
            email: User's email address
            password: Plain text password
            user_agent: Client user agent
            ip_address: Client IP address

        Returns:
            Tuple of (user, token_pair)

        Raises:
            UnauthorizedError: If credentials are invalid
        """
        # Find user by email (system-level: tenant not known during login)
        user = await self.user_repo.get_by_email_system(email)
        if not user:
            raise UnauthorizedError(
                "Invalid email or password",
                error_code="invalid_credentials",
            )

        # Verify password
        if not user.password_hash or not verify_password(password, user.password_hash):
            raise UnauthorizedError(
                "Invalid email or password",
                error_code="invalid_credentials",
            )

        # Check if user is active
        if not user.is_active:
            raise UnauthorizedError(
                "Account is deactivated",
                error_code="account_inactive",
            )

        # Generate tokens
        token_pair = await self._create_tokens(user, user_agent, ip_address)

        return user, token_pair

    async def refresh_tokens(
        self,
        refresh_token: str,
        user_agent: str | None = None,
        ip_address: str | None = None,
    ) -> TokenPair:
        """Refresh the access token using a refresh token.

        The old refresh token is revoked and a new one is issued.

        Args:
            refresh_token: The refresh token
            user_agent: Client user agent
            ip_address: Client IP address

        Returns:
            New token pair

        Raises:
            UnauthorizedError: If refresh token is invalid or revoked
        """
        # Find token by hash
        token_hash = hash_token(refresh_token)
        stored_token = await self.token_repo.get_by_hash(token_hash)

        if not stored_token:
            raise UnauthorizedError(
                "Invalid refresh token",
                error_code="invalid_refresh_token",
            )

        # Check expiration
        if stored_token.expires_at < datetime.now(UTC):
            await self.token_repo.revoke(stored_token)
            raise UnauthorizedError(
                "Refresh token expired",
                error_code="token_expired",
            )

        # Get user (system-level: validating token, not user-initiated request)
        user = await self.user_repo.get_by_id_system(stored_token.user_id)
        if not user or not user.is_active:
            await self.token_repo.revoke(stored_token)
            raise UnauthorizedError(
                "User not found or inactive",
                error_code="user_invalid",
            )

        # Revoke old token
        await self.token_repo.revoke(stored_token)

        # Generate new tokens
        return await self._create_tokens(user, user_agent, ip_address)

    async def logout(self, refresh_token: str) -> None:
        """Logout by revoking the refresh token.

        Args:
            refresh_token: The refresh token to revoke
        """
        token_hash = hash_token(refresh_token)
        stored_token = await self.token_repo.get_by_hash(token_hash)
        if stored_token:
            await self.token_repo.revoke(stored_token)

    async def logout_all(self, user_id: UUID) -> int:
        """Logout from all devices by revoking all refresh tokens.

        Args:
            user_id: The user's UUID

        Returns:
            Number of tokens revoked
        """
        return await self.token_repo.revoke_all_for_user(user_id)

    async def _create_tokens(
        self,
        user: User,
        user_agent: str | None = None,
        ip_address: str | None = None,
    ) -> TokenPair:
        """Create a new token pair for a user.

        Args:
            user: The user to create tokens for
            user_agent: Client user agent
            ip_address: Client IP address

        Returns:
            TokenPair with access and refresh tokens
        """
        # Create access token
        access_token = create_access_token(user.id, user.tenant_id)

        # Create refresh token
        refresh_token = create_refresh_token(user.id, user.tenant_id)
        expires_at = get_token_expiration()

        # Store refresh token
        stored_token = RefreshToken(
            user_id=user.id,
            token_hash=hash_token(refresh_token),
            expires_at=expires_at,
            user_agent=user_agent,
            ip_address=ip_address,
        )
        await self.token_repo.create(stored_token)

        return TokenPair(
            access_token=access_token,
            refresh_token=refresh_token,
            expires_in=settings.access_token_expire_minutes * 60,
        )


# Type alias for dependency injection
AuthSvc = Annotated[AuthService, Depends(AuthService)]

