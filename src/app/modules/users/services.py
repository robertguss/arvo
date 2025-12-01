"""User service for business logic."""

from typing import Annotated
from uuid import UUID

from fastapi import Depends

from app.core.errors import ConflictError, NotFoundError
from app.modules.users.models import User
from app.modules.users.repos import UserRepo
from app.modules.users.schemas import UserCreate, UserCreateOAuth, UserUpdate


class UserService:
    """Service for user management operations.

    Contains business logic for user CRUD operations,
    password management, and user queries.
    """

    def __init__(self, repo: UserRepo) -> None:
        self.repo = repo

    async def create_user(
        self,
        data: UserCreate,
        tenant_id: UUID,
        password_hash: str,
    ) -> User:
        """Create a new user with password.

        Args:
            data: User creation data
            tenant_id: The tenant this user belongs to
            password_hash: Pre-hashed password

        Returns:
            The created user

        Raises:
            ConflictError: If email already exists for this tenant
        """
        # Check for existing email (P3-1: generic message to prevent enumeration)
        existing = await self.repo.get_by_email(data.email, tenant_id)
        if existing:
            raise ConflictError(
                "Registration failed. If this email is already registered, please use the login page.",
                error_code="registration_failed",
            )

        user = User(
            email=data.email,
            full_name=data.full_name,
            password_hash=password_hash,
            tenant_id=tenant_id,
        )
        return await self.repo.create(user)

    async def create_oauth_user(
        self,
        data: UserCreateOAuth,
        tenant_id: UUID,
    ) -> User:
        """Create a new user from OAuth data.

        Args:
            data: OAuth user data
            tenant_id: The tenant this user belongs to

        Returns:
            The created user

        Raises:
            ConflictError: If OAuth ID already exists
        """
        # Check for existing OAuth user within tenant
        existing = await self.repo.get_by_oauth(
            data.oauth_provider, data.oauth_id, tenant_id
        )
        if existing:
            raise ConflictError(
                "OAuth account already linked",
                error_code="oauth_exists",
            )

        user = User(
            email=data.email,
            full_name=data.full_name,
            oauth_provider=data.oauth_provider,
            oauth_id=data.oauth_id,
            tenant_id=tenant_id,
        )
        return await self.repo.create(user)

    async def get_user(self, user_id: UUID, tenant_id: UUID) -> User:
        """Get a user by ID, scoped to tenant.

        Args:
            user_id: The user's UUID
            tenant_id: The tenant scope (required for security)

        Returns:
            The user

        Raises:
            NotFoundError: If user not found within tenant
        """
        user = await self.repo.get_by_id(user_id, tenant_id)
        if not user:
            raise NotFoundError(
                "User not found",
                resource="user",
                resource_id=str(user_id),
            )
        return user

    async def get_user_by_email(self, email: str, tenant_id: UUID) -> User | None:
        """Get a user by email, scoped to tenant.

        Args:
            email: The email address
            tenant_id: The tenant scope (required for security)

        Returns:
            User if found within tenant, None otherwise
        """
        return await self.repo.get_by_email(email, tenant_id)

    async def get_or_create_oauth_user(
        self,
        email: str,
        full_name: str,
        oauth_provider: str,
        oauth_id: str,
        tenant_id: UUID,
    ) -> tuple[User, bool]:
        """Get or create a user from OAuth data within a tenant.

        Args:
            email: User's email
            full_name: User's name
            oauth_provider: OAuth provider name
            oauth_id: User's ID from provider
            tenant_id: The tenant ID

        Returns:
            Tuple of (user, was_created)
        """
        # Try to find by OAuth ID first within tenant
        user = await self.repo.get_by_oauth(oauth_provider, oauth_id, tenant_id)
        if user:
            return user, False

        # Try to find by email within tenant and link OAuth
        user = await self.repo.get_by_email(email, tenant_id)
        if user:
            user.oauth_provider = oauth_provider
            user.oauth_id = oauth_id
            await self.repo.update(user)
            return user, False

        # Create new user
        user = User(
            email=email,
            full_name=full_name,
            oauth_provider=oauth_provider,
            oauth_id=oauth_id,
            tenant_id=tenant_id,
        )
        user = await self.repo.create(user)
        return user, True

    async def update_user(
        self,
        user_id: UUID,
        data: UserUpdate,
        tenant_id: UUID,
    ) -> User:
        """Update a user.

        Args:
            user_id: The user's UUID
            data: Update data
            tenant_id: The tenant scope

        Returns:
            The updated user

        Raises:
            NotFoundError: If user not found
            ConflictError: If new email already exists
        """
        user = await self.get_user(user_id, tenant_id)

        if data.email and data.email != user.email:
            existing = await self.repo.get_by_email(data.email, tenant_id)
            if existing:
                raise ConflictError(
                    "Email already in use",
                    error_code="email_exists",
                    details={"email": data.email},
                )
            user.email = data.email

        if data.full_name:
            user.full_name = data.full_name

        return await self.repo.update(user)

    async def list_users(
        self,
        tenant_id: UUID,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[User], int]:
        """List users for a tenant.

        Args:
            tenant_id: The tenant's UUID
            page: Page number
            page_size: Items per page

        Returns:
            Tuple of (users list, total count)
        """
        return await self.repo.list_by_tenant(tenant_id, page, page_size)

    async def deactivate_user(self, user_id: UUID, tenant_id: UUID) -> User:
        """Deactivate a user.

        Args:
            user_id: The user's UUID
            tenant_id: The tenant scope

        Returns:
            The deactivated user
        """
        user = await self.get_user(user_id, tenant_id)
        user.is_active = False
        return await self.repo.update(user)

    async def activate_user(self, user_id: UUID, tenant_id: UUID) -> User:
        """Activate a user.

        Args:
            user_id: The user's UUID
            tenant_id: The tenant scope

        Returns:
            The activated user
        """
        user = await self.get_user(user_id, tenant_id)
        user.is_active = True
        return await self.repo.update(user)


# Type alias for dependency injection
UserSvc = Annotated[UserService, Depends(UserService)]
