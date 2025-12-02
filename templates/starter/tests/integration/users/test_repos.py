"""Integration tests for user repositories."""

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.tenants.models import Tenant
from app.modules.users.models import RefreshToken, RevokedToken, User
from app.modules.users.repos import (
    RefreshTokenRepository,
    RevokedTokenRepository,
    UserRepository,
)


async def create_test_user(
    db: AsyncSession,
    tenant: Tenant,
    email: str = "testuser@example.com",
    oauth_provider: str | None = None,
    oauth_id: str | None = None,
) -> User:
    """Helper to create a user for testing."""
    user = User(
        email=email,
        full_name="Test User",
        password_hash="testhash123",
        tenant_id=tenant.id,
        oauth_provider=oauth_provider,
        oauth_id=oauth_id,
    )
    db.add(user)
    await db.flush()
    return user


class TestUserRepositoryCreate:
    """Tests for UserRepository.create method."""

    @pytest.mark.asyncio
    async def test_create_user(self, db: AsyncSession, tenant: Tenant):
        """Verify user is created and returned with ID."""
        repo = UserRepository(db)
        user = User(
            email="newuser@example.com",
            full_name="New User",
            password_hash="hash",
            tenant_id=tenant.id,
        )

        result = await repo.create(user)

        assert result.id is not None
        assert result.email == "newuser@example.com"
        assert result.tenant_id == tenant.id


class TestUserRepositoryGetById:
    """Tests for UserRepository.get_by_id method."""

    @pytest.mark.asyncio
    async def test_get_by_id_found(self, db: AsyncSession, tenant: Tenant):
        """Verify user is found when ID and tenant match."""
        user = await create_test_user(db, tenant, "getbyid@example.com")
        repo = UserRepository(db)

        result = await repo.get_by_id(user.id, tenant.id)

        assert result is not None
        assert result.id == user.id

    @pytest.mark.asyncio
    async def test_get_by_id_wrong_tenant_not_found(
        self, db: AsyncSession, tenant: Tenant
    ):
        """Verify user is not found when tenant doesn't match."""
        user = await create_test_user(db, tenant, "wrongtenant@example.com")
        repo = UserRepository(db)
        wrong_tenant_id = uuid4()

        result = await repo.get_by_id(user.id, wrong_tenant_id)

        assert result is None

    @pytest.mark.asyncio
    async def test_get_by_id_nonexistent(
        self, db: AsyncSession, tenant: Tenant
    ):
        """Verify None returned for non-existent user."""
        repo = UserRepository(db)

        result = await repo.get_by_id(uuid4(), tenant.id)

        assert result is None


class TestUserRepositoryGetByIdSystem:
    """Tests for UserRepository.get_by_id_system method."""

    @pytest.mark.asyncio
    async def test_get_by_id_system_found(self, db: AsyncSession, tenant: Tenant):
        """Verify user is found without tenant filter."""
        user = await create_test_user(db, tenant, "system@example.com")
        repo = UserRepository(db)

        result = await repo.get_by_id_system(user.id)

        assert result is not None
        assert result.id == user.id

    @pytest.mark.asyncio
    async def test_get_by_id_system_nonexistent(self, db: AsyncSession):
        """Verify None returned for non-existent user."""
        repo = UserRepository(db)

        result = await repo.get_by_id_system(uuid4())

        assert result is None


class TestUserRepositoryGetByEmail:
    """Tests for UserRepository.get_by_email method."""

    @pytest.mark.asyncio
    async def test_get_by_email_found(
        self, db: AsyncSession, tenant: Tenant
    ):
        """Verify user is found by email in tenant."""
        user = await create_test_user(db, tenant, "findme@example.com")
        repo = UserRepository(db)

        result = await repo.get_by_email(user.email, tenant.id)

        assert result is not None
        assert result.email == user.email

    @pytest.mark.asyncio
    async def test_get_by_email_wrong_tenant(
        self, db: AsyncSession, tenant: Tenant
    ):
        """Verify user is not found in wrong tenant."""
        user = await create_test_user(db, tenant, "wrongtenant2@example.com")
        repo = UserRepository(db)

        result = await repo.get_by_email(user.email, uuid4())

        assert result is None


class TestUserRepositoryGetByOAuth:
    """Tests for UserRepository.get_by_oauth method."""

    @pytest.mark.asyncio
    async def test_get_by_oauth_found(self, db: AsyncSession, tenant: Tenant):
        """Verify OAuth user is found."""
        user = await create_test_user(
            db, tenant, "oauth@example.com", oauth_provider="google", oauth_id="google123"
        )
        repo = UserRepository(db)

        result = await repo.get_by_oauth("google", "google123", tenant.id)

        assert result is not None
        assert result.oauth_id == "google123"

    @pytest.mark.asyncio
    async def test_get_by_oauth_not_found(self, db: AsyncSession, tenant: Tenant):
        """Verify None returned for non-existent OAuth user."""
        repo = UserRepository(db)

        result = await repo.get_by_oauth("github", "nonexistent", tenant.id)

        assert result is None


class TestUserRepositoryListByTenant:
    """Tests for UserRepository.list_by_tenant method."""

    @pytest.mark.asyncio
    async def test_list_by_tenant_with_pagination(
        self, db: AsyncSession, tenant: Tenant
    ):
        """Verify users are listed with pagination."""
        # Create multiple users
        for i in range(5):
            await create_test_user(db, tenant, f"listuser{i}@example.com")

        repo = UserRepository(db)
        users, total = await repo.list_by_tenant(tenant.id, page=1, page_size=3)

        assert len(users) == 3
        assert total == 5

    @pytest.mark.asyncio
    async def test_list_by_tenant_second_page(
        self, db: AsyncSession, tenant: Tenant
    ):
        """Verify second page returns remaining users."""
        # Create 5 users
        for i in range(5):
            await create_test_user(db, tenant, f"page2user{i}@example.com")

        repo = UserRepository(db)
        users, total = await repo.list_by_tenant(tenant.id, page=2, page_size=3)

        assert len(users) == 2  # 5 - 3 = 2 remaining
        assert total == 5


class TestUserRepositoryUpdate:
    """Tests for UserRepository.update method."""

    @pytest.mark.asyncio
    async def test_update_user(self, db: AsyncSession, tenant: Tenant):
        """Verify user is updated."""
        user = await create_test_user(db, tenant, "update@example.com")
        repo = UserRepository(db)
        user.full_name = "Updated Name"

        result = await repo.update(user)

        assert result.full_name == "Updated Name"


class TestUserRepositoryDelete:
    """Tests for UserRepository.delete method."""

    @pytest.mark.asyncio
    async def test_delete_user(self, db: AsyncSession, tenant: Tenant):
        """Verify user is deleted."""
        user = await create_test_user(db, tenant, "todelete@example.com")
        user_id = user.id
        repo = UserRepository(db)

        await repo.delete(user)

        result = await repo.get_by_id(user_id, tenant.id)
        assert result is None


class TestRefreshTokenRepository:
    """Tests for RefreshTokenRepository."""

    @pytest.mark.asyncio
    async def test_create_and_get_by_hash(self, db: AsyncSession, tenant: Tenant):
        """Verify token is created and retrievable by hash."""
        user = await create_test_user(db, tenant, "refresh@example.com")
        repo = RefreshTokenRepository(db)
        token = RefreshToken(
            user_id=user.id,
            token_hash="uniquehash12345",
            expires_at=datetime.now(UTC) + timedelta(days=7),
        )

        await repo.create(token)
        result = await repo.get_by_hash("uniquehash12345")

        assert result is not None
        assert result.user_id == user.id

    @pytest.mark.asyncio
    async def test_get_by_hash_not_found(self, db: AsyncSession):
        """Verify None returned for non-existent hash."""
        repo = RefreshTokenRepository(db)

        result = await repo.get_by_hash("nonexistenthash")

        assert result is None

    @pytest.mark.asyncio
    async def test_revoke_token(self, db: AsyncSession, tenant: Tenant):
        """Verify token is revoked."""
        user = await create_test_user(db, tenant, "revoke@example.com")
        repo = RefreshTokenRepository(db)
        token = RefreshToken(
            user_id=user.id,
            token_hash="torevoketoken",
            expires_at=datetime.now(UTC) + timedelta(days=7),
        )
        await repo.create(token)

        await repo.revoke(token)

        # Revoked tokens should not be returned by get_by_hash
        result = await repo.get_by_hash("torevoketoken")
        assert result is None

    @pytest.mark.asyncio
    async def test_revoke_all_for_user(self, db: AsyncSession, tenant: Tenant):
        """Verify all tokens for user are revoked."""
        user = await create_test_user(db, tenant, "revokeall@example.com")
        repo = RefreshTokenRepository(db)

        # Create multiple tokens
        for i in range(3):
            token = RefreshToken(
                user_id=user.id,
                token_hash=f"multitoken{i}",
                expires_at=datetime.now(UTC) + timedelta(days=7),
            )
            await repo.create(token)

        count = await repo.revoke_all_for_user(user.id)

        assert count == 3


class TestRevokedTokenRepository:
    """Tests for RevokedTokenRepository."""

    @pytest.mark.asyncio
    async def test_revoke_and_is_revoked(self, db: AsyncSession):
        """Verify token JTI is revoked and detected."""
        repo = RevokedTokenRepository(db)
        jti = "test-jti-123"
        expires = datetime.now(UTC) + timedelta(hours=1)

        await repo.revoke(jti, expires)
        result = await repo.is_revoked(jti)

        assert result is True

    @pytest.mark.asyncio
    async def test_is_revoked_not_found(self, db: AsyncSession):
        """Verify False returned for non-revoked JTI."""
        repo = RevokedTokenRepository(db)

        result = await repo.is_revoked("nonexistent-jti")

        assert result is False
