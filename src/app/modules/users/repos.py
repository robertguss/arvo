"""User repository for database operations."""

from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import Depends
from sqlalchemy import func, select

from app.api.dependencies import DBSession
from app.modules.users.models import RefreshToken, User


class UserRepository:
    """Repository for User database operations.

    Handles all database interactions for the User model.
    All queries are scoped to a tenant when appropriate.
    """

    def __init__(self, session: DBSession) -> None:
        self.session = session

    async def create(self, user: User) -> User:
        """Create a new user.

        Args:
            user: User instance to create

        Returns:
            The created user with ID populated
        """
        self.session.add(user)
        await self.session.flush()
        await self.session.refresh(user)
        return user

    async def get_by_id(self, user_id: UUID, tenant_id: UUID | None = None) -> User | None:
        """Get a user by ID.

        Args:
            user_id: The user's UUID
            tenant_id: Optional tenant ID for scoping

        Returns:
            User if found, None otherwise
        """
        stmt = select(User).where(User.id == user_id)
        if tenant_id:
            stmt = stmt.where(User.tenant_id == tenant_id)
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def get_by_email(self, email: str, tenant_id: UUID | None = None) -> User | None:
        """Get a user by email address.

        Args:
            email: The user's email
            tenant_id: Optional tenant ID for scoping

        Returns:
            User if found, None otherwise
        """
        stmt = select(User).where(User.email == email)
        if tenant_id:
            stmt = stmt.where(User.tenant_id == tenant_id)
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def get_by_oauth(
        self, provider: str, oauth_id: str, tenant_id: UUID | None = None
    ) -> User | None:
        """Get a user by OAuth provider and ID.

        Args:
            provider: OAuth provider name (google, github, etc.)
            oauth_id: User's ID from the OAuth provider
            tenant_id: Optional tenant ID for scoping

        Returns:
            User if found, None otherwise
        """
        stmt = select(User).where(
            User.oauth_provider == provider,
            User.oauth_id == oauth_id,
        )
        if tenant_id:
            stmt = stmt.where(User.tenant_id == tenant_id)
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def list_by_tenant(
        self,
        tenant_id: UUID,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[User], int]:
        """List users for a tenant with pagination.

        Args:
            tenant_id: The tenant's UUID
            page: Page number (1-indexed)
            page_size: Number of items per page

        Returns:
            Tuple of (users list, total count)
        """
        # Count total
        count_stmt = select(func.count()).select_from(User).where(User.tenant_id == tenant_id)
        count_result = await self.session.execute(count_stmt)
        total = count_result.scalar_one()

        # Get paginated results
        offset = (page - 1) * page_size
        stmt = (
            select(User)
            .where(User.tenant_id == tenant_id)
            .order_by(User.created_at.desc())
            .offset(offset)
            .limit(page_size)
        )
        result = await self.session.execute(stmt)
        users = list(result.scalars().all())

        return users, total

    async def update(self, user: User) -> User:
        """Update a user.

        Args:
            user: User instance with updated fields

        Returns:
            The updated user
        """
        await self.session.flush()
        await self.session.refresh(user)
        return user

    async def delete(self, user: User) -> None:
        """Delete a user.

        Args:
            user: User instance to delete
        """
        await self.session.delete(user)
        await self.session.flush()


class RefreshTokenRepository:
    """Repository for RefreshToken database operations."""

    def __init__(self, session: DBSession) -> None:
        self.session = session

    async def create(self, token: RefreshToken) -> RefreshToken:
        """Create a new refresh token.

        Args:
            token: RefreshToken instance to create

        Returns:
            The created token
        """
        self.session.add(token)
        await self.session.flush()
        await self.session.refresh(token)
        return token

    async def get_by_hash(self, token_hash: str) -> RefreshToken | None:
        """Get a refresh token by its hash.

        Args:
            token_hash: SHA-256 hash of the token

        Returns:
            RefreshToken if found and not revoked, None otherwise
        """
        stmt = select(RefreshToken).where(
            RefreshToken.token_hash == token_hash,
            RefreshToken.revoked == False,  # noqa: E712
        )
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def revoke(self, token: RefreshToken) -> None:
        """Revoke a refresh token.

        Args:
            token: RefreshToken to revoke
        """
        token.revoked = True
        await self.session.flush()

    async def revoke_all_for_user(self, user_id: UUID) -> int:
        """Revoke all refresh tokens for a user.

        Args:
            user_id: The user's UUID

        Returns:
            Number of tokens revoked
        """
        stmt = select(RefreshToken).where(
            RefreshToken.user_id == user_id,
            RefreshToken.revoked == False,  # noqa: E712
        )
        result = await self.session.execute(stmt)
        tokens = result.scalars().all()

        for token in tokens:
            token.revoked = True

        await self.session.flush()
        return len(tokens)

    async def cleanup_expired(self, before: datetime) -> int:
        """Delete expired tokens.

        Args:
            before: Delete tokens that expired before this time

        Returns:
            Number of tokens deleted
        """
        stmt = select(RefreshToken).where(RefreshToken.expires_at < before.isoformat())
        result = await self.session.execute(stmt)
        tokens = result.scalars().all()

        for token in tokens:
            await self.session.delete(token)

        await self.session.flush()
        return len(tokens)


# Type aliases for dependency injection
UserRepo = Annotated[UserRepository, Depends(UserRepository)]
RefreshTokenRepo = Annotated[RefreshTokenRepository, Depends(RefreshTokenRepository)]

