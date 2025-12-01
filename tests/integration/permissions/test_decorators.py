"""Integration tests for permission decorators.

These tests verify the permission decorator behavior on routes including:
- require_permission
- require_any_permission
- require_all_permissions
"""

import pytest
from fastapi import APIRouter
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.dependencies import DBSession
from app.core.auth import hash_password
from app.core.auth.backend import create_access_token
from app.core.auth.dependencies import CurrentUser
from app.core.permissions.decorators import (
    require_all_permissions,
    require_any_permission,
    require_permission,
)
from app.core.permissions.models import Permission, Role, UserRole
from app.modules.tenants.models import Tenant
from app.modules.users.models import User


pytestmark = pytest.mark.integration


# Create a test router with protected endpoints
test_router = APIRouter()


@test_router.get("/protected-single")
@require_permission("resource", "read")
async def protected_single(current_user: CurrentUser, db: DBSession):
    """Endpoint requiring single permission."""
    return {"status": "ok", "user_id": str(current_user.id)}


@test_router.get("/protected-any")
@require_any_permission([("resource", "read"), ("resource", "write")])
async def protected_any(current_user: CurrentUser, db: DBSession):
    """Endpoint requiring any of the permissions."""
    return {"status": "ok", "user_id": str(current_user.id)}


@test_router.get("/protected-all")
@require_all_permissions([("resource", "read"), ("resource", "write")])
async def protected_all(current_user: CurrentUser, db: DBSession):
    """Endpoint requiring all permissions."""
    return {"status": "ok", "user_id": str(current_user.id)}


class TestPermissionDecorators:
    """Tests for permission decorators on routes."""

    @pytest.fixture
    async def test_app(self, app):
        """Add test router to app."""
        app.include_router(test_router, prefix="/test")
        return app

    @pytest.fixture
    async def test_client(self, test_app) -> AsyncClient:
        """Create test client for the app."""
        async with AsyncClient(
            transport=ASGITransport(app=test_app),
            base_url="http://test",
        ) as client:
            yield client

    @pytest.fixture
    async def tenant(self, db: AsyncSession) -> Tenant:
        """Create test tenant."""
        tenant = Tenant(name="Perm Test Tenant", slug="perm-test-tenant")
        db.add(tenant)
        await db.flush()
        return tenant

    @pytest.fixture
    async def permission_read(self, db: AsyncSession) -> Permission:
        """Create read permission."""
        perm = Permission(resource="resource", action="read")
        db.add(perm)
        await db.flush()
        return perm

    @pytest.fixture
    async def permission_write(self, db: AsyncSession) -> Permission:
        """Create write permission."""
        perm = Permission(resource="resource", action="write")
        db.add(perm)
        await db.flush()
        return perm

    @pytest.fixture
    async def role_reader(
        self,
        db: AsyncSession,
        tenant: Tenant,
        permission_read: Permission,
    ) -> Role:
        """Create role with read permission only."""
        role = Role(name="reader", tenant_id=tenant.id)
        role.permissions.append(permission_read)
        db.add(role)
        await db.flush()
        return role

    @pytest.fixture
    async def role_editor(
        self,
        db: AsyncSession,
        tenant: Tenant,
        permission_read: Permission,
        permission_write: Permission,
    ) -> Role:
        """Create role with read and write permissions."""
        role = Role(name="editor", tenant_id=tenant.id)
        role.permissions.append(permission_read)
        role.permissions.append(permission_write)
        db.add(role)
        await db.flush()
        return role

    @pytest.fixture
    async def user_no_roles(self, db: AsyncSession, tenant: Tenant) -> User:
        """Create user without any roles."""
        user = User(
            email="noroles@example.com",
            password_hash=hash_password("password123"),
            full_name="No Roles",
            tenant_id=tenant.id,
        )
        db.add(user)
        await db.flush()
        return user

    @pytest.fixture
    async def user_reader(
        self,
        db: AsyncSession,
        tenant: Tenant,
        role_reader: Role,
    ) -> User:
        """Create user with reader role."""
        user = User(
            email="reader@example.com",
            password_hash=hash_password("password123"),
            full_name="Reader",
            tenant_id=tenant.id,
        )
        db.add(user)
        await db.flush()

        user_role = UserRole(user_id=user.id, role_id=role_reader.id)
        db.add(user_role)
        await db.flush()

        return user

    @pytest.fixture
    async def user_editor(
        self,
        db: AsyncSession,
        tenant: Tenant,
        role_editor: Role,
    ) -> User:
        """Create user with editor role."""
        user = User(
            email="editor@example.com",
            password_hash=hash_password("password123"),
            full_name="Editor",
            tenant_id=tenant.id,
        )
        db.add(user)
        await db.flush()

        user_role = UserRole(user_id=user.id, role_id=role_editor.id)
        db.add(user_role)
        await db.flush()

        return user

    @pytest.fixture
    async def superuser(self, db: AsyncSession, tenant: Tenant) -> User:
        """Create superuser."""
        user = User(
            email="super@example.com",
            password_hash=hash_password("password123"),
            full_name="Superuser",
            tenant_id=tenant.id,
            is_superuser=True,
        )
        db.add(user)
        await db.flush()
        return user

    async def test_require_permission_denies_unauthenticated(
        self,
        test_client: AsyncClient,
    ):
        """Unauthenticated request should be denied."""
        response = await test_client.get("/test/protected-single")
        assert response.status_code == 401

    async def test_require_permission_allows_authorized(
        self,
        test_client: AsyncClient,
        user_reader: User,
    ):
        """User with required permission should be allowed."""
        token = create_access_token(user_reader.id, user_reader.tenant_id)
        response = await test_client.get(
            "/test/protected-single",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200

    async def test_require_permission_denies_unauthorized(
        self,
        test_client: AsyncClient,
        user_no_roles: User,
    ):
        """User without required permission should be denied."""
        token = create_access_token(user_no_roles.id, user_no_roles.tenant_id)
        response = await test_client.get(
            "/test/protected-single",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 403

    async def test_require_any_permission_allows_if_one_matches(
        self,
        test_client: AsyncClient,
        user_reader: User,
    ):
        """User with any one of required permissions should be allowed."""
        token = create_access_token(user_reader.id, user_reader.tenant_id)
        response = await test_client.get(
            "/test/protected-any",
            headers={"Authorization": f"Bearer {token}"},
        )
        # User has read permission, endpoint requires read OR write
        assert response.status_code == 200

    async def test_require_any_permission_denies_if_none_match(
        self,
        test_client: AsyncClient,
        user_no_roles: User,
    ):
        """User without any of required permissions should be denied."""
        token = create_access_token(user_no_roles.id, user_no_roles.tenant_id)
        response = await test_client.get(
            "/test/protected-any",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 403

    async def test_require_all_permissions_requires_all(
        self,
        test_client: AsyncClient,
        user_editor: User,
    ):
        """User with all required permissions should be allowed."""
        token = create_access_token(user_editor.id, user_editor.tenant_id)
        response = await test_client.get(
            "/test/protected-all",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200

    async def test_require_all_permissions_denies_partial(
        self,
        test_client: AsyncClient,
        user_reader: User,
    ):
        """User with only some required permissions should be denied."""
        token = create_access_token(user_reader.id, user_reader.tenant_id)
        response = await test_client.get(
            "/test/protected-all",
            headers={"Authorization": f"Bearer {token}"},
        )
        # User has read but not write
        assert response.status_code == 403

    async def test_superuser_bypasses_all_checks(
        self,
        test_client: AsyncClient,
        superuser: User,
    ):
        """Superuser should bypass all permission checks."""
        token = create_access_token(superuser.id, superuser.tenant_id)

        # Single permission
        response = await test_client.get(
            "/test/protected-single",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200

        # Any permission
        response = await test_client.get(
            "/test/protected-any",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200

        # All permissions
        response = await test_client.get(
            "/test/protected-all",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200

