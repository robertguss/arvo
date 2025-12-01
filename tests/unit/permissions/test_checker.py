"""Unit tests for permission checker.

These tests verify the PermissionChecker logic including:
- Permission evaluation
- Role-based access
- Wildcard permissions
"""

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import hash_password
from app.core.permissions.checker import PermissionChecker, check_permission
from app.core.permissions.models import Permission, Role, UserRole
from app.modules.tenants.models import Tenant
from app.modules.users.models import User


pytestmark = pytest.mark.unit


class TestPermissionChecker:
    """Tests for PermissionChecker class."""

    @pytest.fixture
    async def tenant(self, db: AsyncSession) -> Tenant:
        """Create test tenant."""
        tenant = Tenant(name="Test Tenant", slug="test-tenant")
        db.add(tenant)
        await db.flush()
        return tenant

    @pytest.fixture
    async def user(self, db: AsyncSession, tenant: Tenant) -> User:
        """Create test user."""
        user = User(
            email="test@example.com",
            password_hash=hash_password("password123"),
            full_name="Test User",
            tenant_id=tenant.id,
            is_superuser=False,
        )
        db.add(user)
        await db.flush()
        return user

    @pytest.fixture
    async def superuser(self, db: AsyncSession, tenant: Tenant) -> User:
        """Create test superuser."""
        user = User(
            email="admin@example.com",
            password_hash=hash_password("password123"),
            full_name="Admin User",
            tenant_id=tenant.id,
            is_superuser=True,
        )
        db.add(user)
        await db.flush()
        return user

    @pytest.fixture
    async def permission_users_read(self, db: AsyncSession) -> Permission:
        """Create users:read permission."""
        perm = Permission(resource="users", action="read", description="Read users")
        db.add(perm)
        await db.flush()
        return perm

    @pytest.fixture
    async def permission_users_write(self, db: AsyncSession) -> Permission:
        """Create users:write permission."""
        perm = Permission(resource="users", action="write", description="Write users")
        db.add(perm)
        await db.flush()
        return perm

    @pytest.fixture
    async def permission_users_delete(self, db: AsyncSession) -> Permission:
        """Create users:delete permission."""
        perm = Permission(resource="users", action="delete", description="Delete users")
        db.add(perm)
        await db.flush()
        return perm

    @pytest.fixture
    async def permission_wildcard(self, db: AsyncSession) -> Permission:
        """Create wildcard permission."""
        perm = Permission(resource="*", action="*", description="Full access")
        db.add(perm)
        await db.flush()
        return perm

    @pytest.fixture
    async def role_viewer(
        self,
        db: AsyncSession,
        tenant: Tenant,
        permission_users_read: Permission,
    ) -> Role:
        """Create viewer role with read permission."""
        role = Role(
            name="viewer",
            description="View-only access",
            tenant_id=tenant.id,
        )
        role.permissions.append(permission_users_read)
        db.add(role)
        await db.flush()
        return role

    @pytest.fixture
    async def role_editor(
        self,
        db: AsyncSession,
        tenant: Tenant,
        permission_users_read: Permission,
        permission_users_write: Permission,
    ) -> Role:
        """Create editor role with read/write permissions."""
        role = Role(
            name="editor",
            description="Read and write access",
            tenant_id=tenant.id,
        )
        role.permissions.append(permission_users_read)
        role.permissions.append(permission_users_write)
        db.add(role)
        await db.flush()
        return role

    @pytest.fixture
    async def role_admin(
        self,
        db: AsyncSession,
        tenant: Tenant,
        permission_wildcard: Permission,
    ) -> Role:
        """Create admin role with wildcard permission."""
        role = Role(
            name="admin",
            description="Full access",
            tenant_id=tenant.id,
        )
        role.permissions.append(permission_wildcard)
        db.add(role)
        await db.flush()
        return role

    async def test_user_with_permission_allowed(
        self,
        db: AsyncSession,
        user: User,
        role_viewer: Role,
    ):
        """User with required permission should be allowed."""
        # Assign role to user
        user_role = UserRole(user_id=user.id, role_id=role_viewer.id)
        db.add(user_role)
        await db.flush()

        checker = PermissionChecker(db)
        result = await checker.has_permission(
            user.id,
            user.tenant_id,
            "users",
            "read",
        )

        assert result is True

    async def test_user_without_permission_denied(
        self,
        db: AsyncSession,
        user: User,
        role_viewer: Role,
    ):
        """User without required permission should be denied."""
        # Assign role to user (only has read permission)
        user_role = UserRole(user_id=user.id, role_id=role_viewer.id)
        db.add(user_role)
        await db.flush()

        checker = PermissionChecker(db)

        # Try to check for write permission (user only has read)
        result = await checker.has_permission(
            user.id,
            user.tenant_id,
            "users",
            "write",
        )

        assert result is False

    async def test_user_without_any_role_denied(
        self,
        db: AsyncSession,
        user: User,
    ):
        """User without any role should be denied."""
        checker = PermissionChecker(db)
        result = await checker.has_permission(
            user.id,
            user.tenant_id,
            "users",
            "read",
        )

        assert result is False

    async def test_wildcard_permission_matches(
        self,
        db: AsyncSession,
        user: User,
        role_admin: Role,
    ):
        """Wildcard permission should match any resource/action."""
        # Assign admin role with wildcard permission
        user_role = UserRole(user_id=user.id, role_id=role_admin.id)
        db.add(user_role)
        await db.flush()

        checker = PermissionChecker(db)

        # Should match any permission
        assert await checker.has_permission(user.id, user.tenant_id, "users", "read")
        assert await checker.has_permission(user.id, user.tenant_id, "users", "write")
        assert await checker.has_permission(user.id, user.tenant_id, "projects", "delete")
        assert await checker.has_permission(user.id, user.tenant_id, "anything", "whatever")

    async def test_has_any_permission(
        self,
        db: AsyncSession,
        user: User,
        role_viewer: Role,
    ):
        """has_any_permission should return True if user has any one of the permissions."""
        user_role = UserRole(user_id=user.id, role_id=role_viewer.id)
        db.add(user_role)
        await db.flush()

        checker = PermissionChecker(db)

        # User has read, so any of [read, write] should pass
        result = await checker.has_any_permission(
            user.id,
            user.tenant_id,
            [("users", "read"), ("users", "write")],
        )
        assert result is True

        # User doesn't have write or delete
        result = await checker.has_any_permission(
            user.id,
            user.tenant_id,
            [("users", "write"), ("users", "delete")],
        )
        assert result is False

    async def test_has_all_permissions(
        self,
        db: AsyncSession,
        user: User,
        role_editor: Role,
    ):
        """has_all_permissions should return True only if user has all permissions."""
        user_role = UserRole(user_id=user.id, role_id=role_editor.id)
        db.add(user_role)
        await db.flush()

        checker = PermissionChecker(db)

        # User has both read and write
        result = await checker.has_all_permissions(
            user.id,
            user.tenant_id,
            [("users", "read"), ("users", "write")],
        )
        assert result is True

        # User doesn't have delete
        result = await checker.has_all_permissions(
            user.id,
            user.tenant_id,
            [("users", "read"), ("users", "delete")],
        )
        assert result is False

    async def test_get_user_permissions(
        self,
        db: AsyncSession,
        user: User,
        role_editor: Role,
    ):
        """get_user_permissions should return all user permissions."""
        user_role = UserRole(user_id=user.id, role_id=role_editor.id)
        db.add(user_role)
        await db.flush()

        checker = PermissionChecker(db)
        permissions = await checker.get_user_permissions(user.id, user.tenant_id)

        assert "users:read" in permissions
        assert "users:write" in permissions
        assert len(permissions) == 2


class TestCheckPermissionFunction:
    """Tests for the check_permission convenience function."""

    @pytest.fixture
    async def tenant(self, db: AsyncSession) -> Tenant:
        """Create test tenant."""
        tenant = Tenant(name="Test Tenant", slug="test-tenant-fn")
        db.add(tenant)
        await db.flush()
        return tenant

    @pytest.fixture
    async def superuser(self, db: AsyncSession, tenant: Tenant) -> User:
        """Create test superuser."""
        user = User(
            email="super@example.com",
            password_hash=hash_password("password123"),
            full_name="Super User",
            tenant_id=tenant.id,
            is_superuser=True,
        )
        db.add(user)
        await db.flush()
        return user

    @pytest.fixture
    async def regular_user(self, db: AsyncSession, tenant: Tenant) -> User:
        """Create regular user."""
        user = User(
            email="regular@example.com",
            password_hash=hash_password("password123"),
            full_name="Regular User",
            tenant_id=tenant.id,
            is_superuser=False,
        )
        db.add(user)
        await db.flush()
        return user

    async def test_superuser_bypasses_permission_check(
        self,
        db: AsyncSession,
        superuser: User,
    ):
        """Superuser should bypass all permission checks."""
        # Superuser has no roles, but should still pass
        result = await check_permission(superuser, "users", "delete", db)
        assert result is True

        result = await check_permission(superuser, "anything", "whatever", db)
        assert result is True

    async def test_regular_user_requires_permission(
        self,
        db: AsyncSession,
        regular_user: User,
    ):
        """Regular user without permission should fail."""
        result = await check_permission(regular_user, "users", "delete", db)
        assert result is False

