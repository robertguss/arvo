"""Integration tests for multi-tenancy isolation.

These tests verify that tenant isolation is properly enforced
and users cannot access data from other tenants.
"""

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import hash_password
from app.core.auth.backend import create_access_token
from app.modules.tenants.models import Tenant
from app.modules.users.models import User
from app.modules.users.repos import UserRepository


pytestmark = pytest.mark.integration


class TestTenantIsolation:
    """Tests for multi-tenant data isolation."""

    @pytest.fixture
    async def tenant_a(self, db: AsyncSession) -> Tenant:
        """Create tenant A for testing."""
        tenant = Tenant(name="Tenant A", slug="tenant-a")
        db.add(tenant)
        await db.flush()
        return tenant

    @pytest.fixture
    async def tenant_b(self, db: AsyncSession) -> Tenant:
        """Create tenant B for testing."""
        tenant = Tenant(name="Tenant B", slug="tenant-b")
        db.add(tenant)
        await db.flush()
        return tenant

    @pytest.fixture
    async def user_a(self, db: AsyncSession, tenant_a: Tenant) -> User:
        """Create user in tenant A."""
        user = User(
            email="user-a@example.com",
            password_hash=hash_password("password123"),
            full_name="User A",
            tenant_id=tenant_a.id,
        )
        db.add(user)
        await db.flush()
        return user

    @pytest.fixture
    async def user_b(self, db: AsyncSession, tenant_b: Tenant) -> User:
        """Create user in tenant B."""
        user = User(
            email="user-b@example.com",
            password_hash=hash_password("password123"),
            full_name="User B",
            tenant_id=tenant_b.id,
        )
        db.add(user)
        await db.flush()
        return user

    @pytest.fixture
    def token_a(self, user_a: User) -> str:
        """Create access token for user A."""
        return create_access_token(user_a.id, user_a.tenant_id)

    @pytest.fixture
    def token_b(self, user_b: User) -> str:
        """Create access token for user B."""
        return create_access_token(user_b.id, user_b.tenant_id)

    async def test_user_cannot_access_other_tenant_users_via_repo(
        self,
        db: AsyncSession,
        user_a: User,
        user_b: User,
        tenant_a: Tenant,
        tenant_b: Tenant,
    ):
        """Repository get_by_id should not return users from other tenants."""
        repo = UserRepository(db)

        # User A should find themselves in tenant A
        result = await repo.get_by_id(user_a.id, tenant_a.id)
        assert result is not None
        assert result.id == user_a.id

        # User A should NOT find user B in tenant A
        result = await repo.get_by_id(user_b.id, tenant_a.id)
        assert result is None

        # User A's ID should NOT be found in tenant B
        result = await repo.get_by_id(user_a.id, tenant_b.id)
        assert result is None

    async def test_user_cannot_find_other_tenant_users_by_email(
        self,
        db: AsyncSession,
        user_a: User,
        user_b: User,
        tenant_a: Tenant,
        tenant_b: Tenant,
    ):
        """Repository get_by_email should not return users from other tenants."""
        repo = UserRepository(db)

        # User A's email should be found in tenant A
        result = await repo.get_by_email(user_a.email, tenant_a.id)
        assert result is not None
        assert result.id == user_a.id

        # User B's email should NOT be found in tenant A
        result = await repo.get_by_email(user_b.email, tenant_a.id)
        assert result is None

    async def test_user_listing_is_tenant_scoped(
        self,
        db: AsyncSession,
        user_a: User,
        user_b: User,
        tenant_a: Tenant,
        tenant_b: Tenant,
    ):
        """Repository list_by_tenant should only return users from that tenant."""
        repo = UserRepository(db)

        # List users in tenant A
        users_a, count_a = await repo.list_by_tenant(tenant_a.id)
        assert count_a == 1
        assert len(users_a) == 1
        assert users_a[0].id == user_a.id

        # List users in tenant B
        users_b, count_b = await repo.list_by_tenant(tenant_b.id)
        assert count_b == 1
        assert len(users_b) == 1
        assert users_b[0].id == user_b.id

    async def test_api_returns_only_own_tenant_user(
        self,
        client: AsyncClient,
        user_a: User,
        user_b: User,
        token_a: str,
    ):
        """GET /api/v1/auth/me should return only the authenticated user."""
        response = await client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {token_a}"},
        )

        assert response.status_code == 200
        data = response.json()
        assert data["id"] == str(user_a.id)
        assert data["tenant_id"] == str(user_a.tenant_id)

    async def test_token_with_wrong_tenant_cannot_access_user(
        self,
        db: AsyncSession,
        user_a: User,
        tenant_b: Tenant,
    ):
        """A token with mismatched tenant_id should not find the user."""
        # Create a token with user A's ID but tenant B's ID (attack scenario)
        malicious_token_data_user_id = user_a.id
        malicious_token_data_tenant_id = tenant_b.id

        repo = UserRepository(db)

        # The tenant-scoped lookup should fail
        result = await repo.get_by_id(
            malicious_token_data_user_id,
            malicious_token_data_tenant_id,
        )
        assert result is None

    async def test_system_level_methods_work_across_tenants(
        self,
        db: AsyncSession,
        user_a: User,
        user_b: User,
    ):
        """System-level methods should find users regardless of tenant.

        These methods are only for authentication flows before tenant is known.
        """
        repo = UserRepository(db)

        # System-level get_by_id should find both users
        result_a = await repo.get_by_id_system(user_a.id)
        assert result_a is not None
        assert result_a.id == user_a.id

        result_b = await repo.get_by_id_system(user_b.id)
        assert result_b is not None
        assert result_b.id == user_b.id

        # System-level get_by_email should find both users
        result_a = await repo.get_by_email_system(user_a.email)
        assert result_a is not None

        result_b = await repo.get_by_email_system(user_b.email)
        assert result_b is not None

    async def test_oauth_lookup_is_tenant_scoped(
        self,
        db: AsyncSession,
        tenant_a: Tenant,
        tenant_b: Tenant,
    ):
        """OAuth lookups should be tenant-scoped when using regular methods."""
        repo = UserRepository(db)

        # Create OAuth user in tenant A
        oauth_user = User(
            email="oauth@example.com",
            full_name="OAuth User",
            oauth_provider="google",
            oauth_id="google-123",
            tenant_id=tenant_a.id,
        )
        db.add(oauth_user)
        await db.flush()

        # Should find in tenant A
        result = await repo.get_by_oauth("google", "google-123", tenant_a.id)
        assert result is not None
        assert result.id == oauth_user.id

        # Should NOT find in tenant B
        result = await repo.get_by_oauth("google", "google-123", tenant_b.id)
        assert result is None

        # System method should find regardless of tenant
        result = await repo.get_by_oauth_system("google", "google-123")
        assert result is not None
        assert result.id == oauth_user.id


class TestCrossTenantAttackPrevention:
    """Tests specifically for cross-tenant attack scenarios."""

    @pytest.fixture
    async def setup_tenants_and_users(self, db: AsyncSession):
        """Set up test tenants and users."""
        # Create tenants
        tenant_victim = Tenant(name="Victim Corp", slug="victim-corp")
        tenant_attacker = Tenant(name="Attacker Inc", slug="attacker-inc")
        db.add(tenant_victim)
        db.add(tenant_attacker)
        await db.flush()

        # Create users
        admin_victim = User(
            email="admin@victim.com",
            password_hash=hash_password("secret123"),
            full_name="Victim Admin",
            tenant_id=tenant_victim.id,
            is_superuser=True,
        )
        attacker = User(
            email="hacker@attacker.com",
            password_hash=hash_password("hack123"),
            full_name="Attacker",
            tenant_id=tenant_attacker.id,
        )
        db.add(admin_victim)
        db.add(attacker)
        await db.flush()

        return {
            "tenant_victim": tenant_victim,
            "tenant_attacker": tenant_attacker,
            "admin_victim": admin_victim,
            "attacker": attacker,
        }

    async def test_attacker_cannot_enumerate_victim_users(
        self,
        db: AsyncSession,
        setup_tenants_and_users: dict,
    ):
        """Attacker with valid tenant should not see victim tenant users."""
        data = setup_tenants_and_users
        repo = UserRepository(db)

        # Attacker tries to find admin by email in attacker's tenant
        result = await repo.get_by_email(
            data["admin_victim"].email,
            data["tenant_attacker"].id,
        )
        assert result is None

    async def test_attacker_cannot_access_victim_by_guessing_id(
        self,
        db: AsyncSession,
        setup_tenants_and_users: dict,
    ):
        """Attacker cannot access victim user even if they know the UUID."""
        data = setup_tenants_and_users
        repo = UserRepository(db)

        # Attacker knows victim admin's UUID (e.g., from a data leak)
        # But they can only query with their own tenant_id
        result = await repo.get_by_id(
            data["admin_victim"].id,
            data["tenant_attacker"].id,
        )
        assert result is None

    async def test_superuser_is_still_tenant_scoped(
        self,
        db: AsyncSession,
        setup_tenants_and_users: dict,
    ):
        """Even superusers should be scoped to their tenant via repository."""
        data = setup_tenants_and_users
        repo = UserRepository(db)

        # Victim admin is a superuser, but repository should still scope
        # Note: The superuser flag bypasses RBAC, not tenant isolation
        result = await repo.get_by_id(
            data["attacker"].id,
            data["tenant_victim"].id,
        )
        assert result is None
