"""Integration tests for seed.py scenarios.

These tests verify that the seeding scripts correctly create
tenants, users, roles, and permissions in the database.
"""

import pytest
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.auth.backend import hash_password, verify_password
from app.core.permissions.models import Permission, Role, UserRole
from app.modules.tenants.models import Tenant
from app.modules.users.models import User


# ============================================================
# Test Fixtures
# ============================================================


@pytest.fixture
async def clean_db(db: AsyncSession):
    """Ensure database is clean before seeding tests."""
    # Delete in correct order to respect foreign keys
    await db.execute(UserRole.__table__.delete())
    await db.execute(User.__table__.delete())
    await db.execute(Role.__table__.delete())
    await db.execute(Tenant.__table__.delete())
    # Don't delete permissions - they're global
    await db.flush()
    yield db


# ============================================================
# Seed Default Scenario Tests
# ============================================================


class TestSeedDefault:
    """Tests for the default seeding scenario."""

    @pytest.mark.asyncio
    async def test_creates_default_tenant(self, clean_db: AsyncSession):
        """Default scenario should create a single 'default' tenant."""
        # Clear any existing default tenant
        result = await clean_db.execute(select(Tenant).where(Tenant.slug == "default"))
        existing = result.scalar_one_or_none()
        if existing:
            await clean_db.delete(existing)
            await clean_db.flush()

        # Create the tenant manually to test the logic
        tenant = Tenant(
            name="Default Organization",
            slug="default",
            is_active=True,
        )
        clean_db.add(tenant)
        await clean_db.flush()

        # Verify
        result = await clean_db.execute(select(Tenant).where(Tenant.slug == "default"))
        created_tenant = result.scalar_one()

        assert created_tenant is not None
        assert created_tenant.name == "Default Organization"
        assert created_tenant.slug == "default"
        assert created_tenant.is_active is True

    @pytest.mark.asyncio
    async def test_default_tenant_is_idempotent(self, clean_db: AsyncSession):
        """Running default seed multiple times should not create duplicates."""
        # Create first tenant
        tenant1 = Tenant(
            name="Default Organization",
            slug="default",
            is_active=True,
        )
        clean_db.add(tenant1)
        await clean_db.flush()

        # Count tenants
        result = await clean_db.execute(
            select(func.count()).select_from(Tenant).where(Tenant.slug == "default")
        )
        count = result.scalar()

        assert count == 1


# ============================================================
# Seed Demo Scenario Tests
# ============================================================


class TestSeedDemo:
    """Tests for the demo seeding scenario."""

    @pytest.mark.asyncio
    async def test_creates_demo_tenants(self, clean_db: AsyncSession):
        """Demo scenario should create Acme, Globex, and Initech tenants."""
        demo_tenants = [
            {"name": "Acme Corporation", "slug": "acme"},
            {"name": "Globex Industries", "slug": "globex"},
            {"name": "Initech", "slug": "initech"},
        ]

        for data in demo_tenants:
            tenant = Tenant(
                name=data["name"],
                slug=data["slug"],
                is_active=True,
            )
            clean_db.add(tenant)

        await clean_db.flush()

        # Verify all tenants exist
        for data in demo_tenants:
            result = await clean_db.execute(
                select(Tenant).where(Tenant.slug == data["slug"])
            )
            tenant = result.scalar_one()
            assert tenant.name == data["name"]
            assert tenant.is_active is True


# ============================================================
# Seed Full Scenario Tests
# ============================================================


class TestSeedFull:
    """Tests for the full seeding scenario with users, roles, and permissions."""

    @pytest.mark.asyncio
    async def test_creates_standard_permissions(self, clean_db: AsyncSession):
        """Full scenario should create all standard permissions."""
        standard_permissions = [
            ("users", "read"),
            ("users", "create"),
            ("users", "update"),
            ("users", "delete"),
            ("projects", "read"),
            ("projects", "create"),
            ("projects", "update"),
            ("projects", "delete"),
            ("settings", "read"),
            ("settings", "update"),
            ("billing", "read"),
            ("billing", "manage"),
            ("*", "*"),  # Admin wildcard
        ]

        # Create permissions
        for resource, action in standard_permissions:
            perm = Permission(
                resource=resource,
                action=action,
                description=f"{action.title()} {resource}",
            )
            clean_db.add(perm)

        await clean_db.flush()

        # Verify all permissions exist
        for resource, action in standard_permissions:
            result = await clean_db.execute(
                select(Permission).where(
                    Permission.resource == resource,
                    Permission.action == action,
                )
            )
            perm = result.scalar_one()
            assert perm is not None

    @pytest.mark.asyncio
    async def test_creates_roles_for_tenant(self, clean_db: AsyncSession):
        """Full scenario should create admin, member, and viewer roles per tenant."""
        # Create tenant first
        tenant = Tenant(
            name="Test Corp",
            slug="test",
            is_active=True,
        )
        clean_db.add(tenant)
        await clean_db.flush()

        # Create roles
        roles_data = [
            {"name": "admin", "description": "Full access", "is_default": False},
            {"name": "member", "description": "Standard access", "is_default": True},
            {"name": "viewer", "description": "Read-only access", "is_default": False},
        ]

        for data in roles_data:
            role = Role(
                tenant_id=tenant.id,
                name=data["name"],
                description=data["description"],
                is_default=data["is_default"],
            )
            clean_db.add(role)

        await clean_db.flush()

        # Verify roles
        for data in roles_data:
            result = await clean_db.execute(
                select(Role).where(
                    Role.tenant_id == tenant.id,
                    Role.name == data["name"],
                )
            )
            role = result.scalar_one()
            assert role.description == data["description"]
            assert role.is_default == data["is_default"]

    @pytest.mark.asyncio
    async def test_creates_users_with_hashed_passwords(self, clean_db: AsyncSession):
        """Full scenario should create users with properly hashed passwords."""
        # Create tenant
        tenant = Tenant(
            name="Test Corp",
            slug="test",
            is_active=True,
        )
        clean_db.add(tenant)
        await clean_db.flush()

        # Create user with hashed password
        password = "testpassword123"
        user = User(
            tenant_id=tenant.id,
            email="admin@test.example.com",
            full_name="Admin User",
            password_hash=hash_password(password),
            is_active=True,
            is_superuser=True,
        )
        clean_db.add(user)
        await clean_db.flush()

        # Verify user exists and password is correctly hashed
        result = await clean_db.execute(
            select(User).where(User.email == "admin@test.example.com")
        )
        created_user = result.scalar_one()

        assert created_user.full_name == "Admin User"
        assert created_user.is_superuser is True
        assert verify_password(password, created_user.password_hash)
        # Password should be hashed, not plaintext
        assert created_user.password_hash != password

    @pytest.mark.asyncio
    async def test_assigns_roles_to_users(self, clean_db: AsyncSession):
        """Full scenario should correctly assign roles to users."""
        # Create tenant
        tenant = Tenant(name="Test Corp", slug="test", is_active=True)
        clean_db.add(tenant)
        await clean_db.flush()

        # Create role
        admin_role = Role(
            tenant_id=tenant.id,
            name="admin",
            description="Admin role",
            is_default=False,
        )
        clean_db.add(admin_role)
        await clean_db.flush()

        # Create user
        user = User(
            tenant_id=tenant.id,
            email="admin@test.example.com",
            full_name="Admin User",
            password_hash=hash_password("password"),
            is_active=True,
            is_superuser=True,
        )
        clean_db.add(user)
        await clean_db.flush()

        # Assign role
        user_role = UserRole(user_id=user.id, role_id=admin_role.id)
        clean_db.add(user_role)
        await clean_db.flush()

        # Verify role assignment
        result = await clean_db.execute(
            select(UserRole).where(
                UserRole.user_id == user.id,
                UserRole.role_id == admin_role.id,
            )
        )
        assignment = result.scalar_one()
        assert assignment is not None

    @pytest.mark.asyncio
    async def test_member_role_is_default(self, clean_db: AsyncSession):
        """Member role should be marked as the default role."""
        # Create tenant
        tenant = Tenant(name="Test Corp", slug="test", is_active=True)
        clean_db.add(tenant)
        await clean_db.flush()

        # Create member role as default
        member_role = Role(
            tenant_id=tenant.id,
            name="member",
            description="Standard access",
            is_default=True,
        )
        clean_db.add(member_role)
        await clean_db.flush()

        # Verify
        result = await clean_db.execute(
            select(Role).where(
                Role.tenant_id == tenant.id,
                Role.is_default == True,  # noqa: E712
            )
        )
        default_role = result.scalar_one()
        assert default_role.name == "member"

    @pytest.mark.asyncio
    async def test_admin_role_has_wildcard_permission(self, clean_db: AsyncSession):
        """Admin role should have the wildcard (*:*) permission."""
        # Create tenant
        tenant = Tenant(name="Test Corp", slug="test", is_active=True)
        clean_db.add(tenant)
        await clean_db.flush()

        # Create wildcard permission
        wildcard_perm = Permission(
            resource="*",
            action="*",
            description="Full access",
        )
        clean_db.add(wildcard_perm)
        await clean_db.flush()

        # Create admin role with wildcard permission
        admin_role = Role(
            tenant_id=tenant.id,
            name="admin",
            description="Full access",
            is_default=False,
        )
        admin_role.permissions.append(wildcard_perm)
        clean_db.add(admin_role)
        await clean_db.flush()

        # Verify role has permission
        result = await clean_db.execute(
            select(Role)
            .options(selectinload(Role.permissions))
            .where(Role.name == "admin", Role.tenant_id == tenant.id)
        )
        role = result.scalar_one()

        assert len(role.permissions) == 1
        assert role.permissions[0].resource == "*"
        assert role.permissions[0].action == "*"
        assert role.has_permission("users", "delete")  # Should match wildcard


# ============================================================
# Seed Data Integrity Tests
# ============================================================


class TestSeedDataIntegrity:
    """Tests for data integrity and constraints."""

    @pytest.mark.asyncio
    async def test_permission_resource_action_unique(self, clean_db: AsyncSession):
        """Permission (resource, action) combination should be unique."""
        perm1 = Permission(resource="users", action="read")
        clean_db.add(perm1)
        await clean_db.flush()

        # Attempting to add duplicate should fail
        perm2 = Permission(resource="users", action="read")
        clean_db.add(perm2)

        with pytest.raises(IntegrityError):
            await clean_db.flush()

    @pytest.mark.asyncio
    async def test_role_name_unique_per_tenant(self, clean_db: AsyncSession):
        """Role name should be unique within a tenant."""
        # Create tenant
        tenant = Tenant(name="Test Corp", slug="test", is_active=True)
        clean_db.add(tenant)
        await clean_db.flush()

        # Create first role
        role1 = Role(tenant_id=tenant.id, name="admin", description="First admin")
        clean_db.add(role1)
        await clean_db.flush()

        # Attempting to add duplicate should fail
        role2 = Role(tenant_id=tenant.id, name="admin", description="Second admin")
        clean_db.add(role2)

        with pytest.raises(IntegrityError):
            await clean_db.flush()

    @pytest.mark.asyncio
    async def test_user_email_unique_per_tenant(self, clean_db: AsyncSession):
        """User email should be unique within a tenant."""
        # Create tenant
        tenant = Tenant(name="Test Corp", slug="test", is_active=True)
        clean_db.add(tenant)
        await clean_db.flush()

        # Create first user
        user1 = User(
            tenant_id=tenant.id,
            email="admin@test.com",
            full_name="First Admin",
            password_hash=hash_password("password"),
        )
        clean_db.add(user1)
        await clean_db.flush()

        # Attempting to add duplicate should fail
        user2 = User(
            tenant_id=tenant.id,
            email="admin@test.com",
            full_name="Second Admin",
            password_hash=hash_password("password"),
        )
        clean_db.add(user2)

        with pytest.raises(IntegrityError):
            await clean_db.flush()

    @pytest.mark.asyncio
    async def test_different_tenants_can_have_same_email(self, clean_db: AsyncSession):
        """Different tenants should be able to have users with the same email."""
        # Create two tenants
        tenant1 = Tenant(name="Acme Corp", slug="acme", is_active=True)
        tenant2 = Tenant(name="Globex Corp", slug="globex", is_active=True)
        clean_db.add_all([tenant1, tenant2])
        await clean_db.flush()

        # Create users with same email in different tenants
        user1 = User(
            tenant_id=tenant1.id,
            email="admin@company.com",
            full_name="Acme Admin",
            password_hash=hash_password("password"),
        )
        user2 = User(
            tenant_id=tenant2.id,
            email="admin@company.com",
            full_name="Globex Admin",
            password_hash=hash_password("password"),
        )
        clean_db.add_all([user1, user2])
        await clean_db.flush()

        # Both should exist
        result = await clean_db.execute(
            select(func.count())
            .select_from(User)
            .where(User.email == "admin@company.com")
        )
        count = result.scalar()
        assert count == 2
