# Test Implementation Guide
## Actionable Code Examples for Phase 3-4

This document provides ready-to-implement code examples for filling critical test gaps identified in `TEST_STRATEGY_REVIEW.md`.

---

## 1. Fix Fixture Scope (Priority: P0 - IMMEDIATE)

### 1.1 Fix conftest.py Engine Fixture

**File:** `tests/conftest.py`

**Current (Lines 28-33):**
```python
@pytest.fixture(scope="session")
def event_loop():
    """Create an instance of the default event loop for the test session."""
    loop = asyncio.get_event_loop_policy().new_event_loop()
    yield loop
    loop.close()
```

**Issues:**
1. Conflicts with `asyncio_mode = "auto"` in pytest config
2. Session-scoped loop conflicts with function-scoped async fixtures
3. pytest-asyncio automatically handles this

**Fix 1: Remove event_loop fixture (RECOMMENDED)**
```python
# DELETE lines 28-33 entirely
# pytest-asyncio v0.24+ handles this automatically
```

**Current (Lines 36-53):**
```python
@pytest.fixture(scope="session")
async def engine():
    """Create test database engine."""
```

**Fix 2: Change engine scope from session to function**
```python
@pytest.fixture  # Remove scope="session" - use default function scope
async def engine():
    """Create test database engine for this test.

    Creates tables at the start and drops them at the end of each test.
    This ensures complete isolation between tests.
    """
    engine = create_async_engine(
        TEST_DATABASE_URL,
        poolclass=NullPool,
        echo=False,
    )

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    yield engine

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)

    await engine.dispose()
```

**Impact:**
- ✅ Fixes "ScopeMismatch" error
- ✅ Enables all 16 integration tests to run
- ✅ Slightly slower (creates/drops tables per test) but guaranteed isolation

---

### 1.2 Add Test Markers to All Tests

**File:** `tests/conftest.py` - Add helper

```python
# Add to conftest.py after imports

import pytest

def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line(
        "markers", "unit: Unit tests (no I/O)"
    )
    config.addinivalue_line(
        "markers", "integration: Integration tests (database)"
    )
    config.addinivalue_line(
        "markers", "e2e: End-to-end tests (full stack)"
    )
    config.addinivalue_line(
        "markers", "slow: Slow tests"
    )
```

**File:** `tests/unit/auth/test_backend.py` - Add markers to ALL tests

```python
"""Unit tests for auth backend (JWT and password handling)."""

from datetime import timedelta
from uuid import uuid4

import pytest

from app.core.auth.backend import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    hash_token,
    verify_password,
)


class TestPasswordHashing:
    """Tests for password hashing functions."""

    @pytest.mark.unit  # ADD THIS
    def test_hash_password_returns_hash(self):
        """hash_password should return a bcrypt hash."""
        password = "mysecretpassword"
        hashed = hash_password(password)

        assert hashed != password
        assert hashed.startswith("$2b$")  # bcrypt prefix

    # ... repeat for all test methods
```

**File:** `tests/integration/api/test_auth.py` - Add marker at module level

```python
"""Integration tests for auth endpoints."""

import pytest
from httpx import AsyncClient

# ... imports ...

# ADD BELOW IMPORTS:
pytestmark = pytest.mark.integration  # Mark all tests in this module

class TestRegistration:
    """Tests for user registration endpoint."""
    # ... tests ...
```

---

## 2. Create Missing Factories (Priority: P1)

### 2.1 Permission Factory

**File:** `tests/factories/permission.py` (NEW)

```python
"""Factory for Permission model."""

from polyfactory.factories.pydantic_factory import ModelFactory

from app.core.permissions.models import Permission


class PermissionFactory(ModelFactory):
    """Factory for generating Permission test data."""

    __model__ = Permission

    @classmethod
    def resource(cls) -> str:
        """Generate a resource name."""
        resources = ["users", "tenants", "billing", "reports", "settings"]
        return resources[hash(cls.__name__) % len(resources)]

    @classmethod
    def action(cls) -> str:
        """Generate an action name."""
        actions = ["read", "write", "delete", "manage"]
        return actions[hash(cls.__name__) % len(actions)]

    @classmethod
    def description(cls) -> str:
        """Generate a permission description."""
        resource = cls.resource()
        action = cls.action()
        return f"Permission to {action} {resource}"
```

### 2.2 Role Factory

**File:** `tests/factories/role.py` (NEW)

```python
"""Factory for Role model."""

from uuid import uuid4

from polyfactory.factories.pydantic_factory import ModelFactory

from app.core.permissions.models import Role


class RoleFactory(ModelFactory):
    """Factory for generating Role test data."""

    __model__ = Role

    @classmethod
    def name(cls) -> str:
        """Generate a role name."""
        roles = ["admin", "member", "viewer", "editor", "manager"]
        return roles[hash(cls.__name__) % len(roles)]

    @classmethod
    def description(cls) -> str:
        """Generate a role description."""
        return f"{cls.name().capitalize()} role"

    @classmethod
    def tenant_id(cls):
        """Generate a tenant ID."""
        return uuid4()

    @classmethod
    def is_default(cls) -> bool:
        """Default to False."""
        return False
```

### 2.3 UserRole Factory

**File:** `tests/factories/user_role.py` (NEW)

```python
"""Factory for UserRole junction model."""

from uuid import uuid4

from polyfactory.factories.pydantic_factory import ModelFactory

from app.core.permissions.models import UserRole


class UserRoleFactory(ModelFactory):
    """Factory for linking users to roles."""

    __model__ = UserRole

    @classmethod
    def user_id(cls):
        """Generate a user ID."""
        return uuid4()

    @classmethod
    def role_id(cls):
        """Generate a role ID."""
        return uuid4()
```

### 2.4 Update Factory __init__.py

**File:** `tests/factories/__init__.py` - Update exports

```python
"""Test factories for generating test data."""

from tests.factories.permission import PermissionFactory
from tests.factories.role import RoleFactory
from tests.factories.tenant import TenantFactory
from tests.factories.user import RefreshTokenFactory, UserCreateFactory, UserFactory
from tests.factories.user_role import UserRoleFactory

__all__ = [
    "PermissionFactory",
    "RefreshTokenFactory",
    "RoleFactory",
    "TenantFactory",
    "UserCreateFactory",
    "UserFactory",
    "UserRoleFactory",
]
```

---

## 3. Add Core Fixtures (Priority: P1)

### 3.1 Enhanced conftest.py with Common Fixtures

**File:** `tests/conftest.py` - Add after existing fixtures (around line 109)

```python
# ============================================================
# Enhanced Test Fixtures for Common Scenarios
# ============================================================


@pytest.fixture
async def admin_user_with_tokens(db: AsyncSession, app):
    """Fixture providing an admin user with valid tokens."""
    from app.modules.tenants.models import Tenant
    from app.modules.users.models import User
    from app.core.auth.backend import hash_password, create_access_token, create_refresh_token
    from app.modules.users.models import RefreshToken
    from app.core.auth.backend import hash_token, get_token_expiration

    # Create tenant
    tenant = Tenant(name="Admin Tenant", slug="admin-tenant")
    db.add(tenant)
    await db.flush()

    # Create admin user
    user = User(
        email="admin@example.com",
        password_hash=hash_password("AdminPassword123!"),
        full_name="Admin User",
        tenant_id=tenant.id,
        is_superuser=True,
        is_active=True,
    )
    db.add(user)
    await db.flush()

    # Create tokens
    access_token = create_access_token(user.id, tenant.id)
    refresh_token_str = create_refresh_token(user.id, tenant.id)
    refresh_token_hash = hash_token(refresh_token_str)
    expires_at = get_token_expiration()

    refresh_token = RefreshToken(
        user_id=user.id,
        token_hash=refresh_token_hash,
        expires_at=expires_at.isoformat(),
    )
    db.add(refresh_token)
    await db.flush()

    return {
        "user": user,
        "tenant": tenant,
        "access_token": access_token,
        "refresh_token": refresh_token_str,
        "user_id": str(user.id),
        "tenant_id": str(tenant.id),
    }


@pytest.fixture
async def regular_user_with_tokens(db: AsyncSession, admin_user_with_tokens):
    """Fixture providing a regular user with valid tokens."""
    from app.modules.users.models import User
    from app.core.auth.backend import hash_password, create_access_token, create_refresh_token
    from app.modules.users.models import RefreshToken
    from app.core.auth.backend import hash_token, get_token_expiration
    from uuid import uuid4

    tenant = admin_user_with_tokens["tenant"]

    # Create regular user (not superuser)
    user = User(
        email="user@example.com",
        password_hash=hash_password("UserPassword123!"),
        full_name="Regular User",
        tenant_id=tenant.id,
        is_superuser=False,
        is_active=True,
    )
    db.add(user)
    await db.flush()

    # Create tokens
    access_token = create_access_token(user.id, tenant.id)
    refresh_token_str = create_refresh_token(user.id, tenant.id)
    refresh_token_hash = hash_token(refresh_token_str)
    expires_at = get_token_expiration()

    refresh_token = RefreshToken(
        user_id=user.id,
        token_hash=refresh_token_hash,
        expires_at=expires_at.isoformat(),
    )
    db.add(refresh_token)
    await db.flush()

    return {
        "user": user,
        "tenant": tenant,
        "access_token": access_token,
        "refresh_token": refresh_token_str,
        "user_id": str(user.id),
        "tenant_id": str(tenant.id),
    }


@pytest.fixture
async def authenticated_client(client: AsyncClient, admin_user_with_tokens) -> AsyncClient:
    """Fixture providing HTTP client authenticated as admin."""
    client.headers["Authorization"] = f"Bearer {admin_user_with_tokens['access_token']}"
    return client


@pytest.fixture
async def roles_and_permissions(db: AsyncSession, admin_user_with_tokens):
    """Fixture providing common roles and permissions."""
    from app.core.permissions.models import Permission, Role
    from app.core.permissions.models import role_permissions
    from sqlalchemy import insert

    tenant = admin_user_with_tokens["tenant"]

    # Create permissions
    read_users_perm = Permission(
        resource="users",
        action="read",
        description="Can read users",
    )
    write_users_perm = Permission(
        resource="users",
        action="write",
        description="Can create/update users",
    )
    delete_users_perm = Permission(
        resource="users",
        action="delete",
        description="Can delete users",
    )

    db.add_all([read_users_perm, write_users_perm, delete_users_perm])
    await db.flush()

    # Create roles
    admin_role = Role(
        name="admin",
        description="Administrator role",
        tenant_id=tenant.id,
        is_default=False,
    )
    member_role = Role(
        name="member",
        description="Member role",
        tenant_id=tenant.id,
        is_default=True,
    )

    db.add_all([admin_role, member_role])
    await db.flush()

    # Link permissions to roles
    admin_permissions = [read_users_perm.id, write_users_perm.id, delete_users_perm.id]
    member_permissions = [read_users_perm.id]

    await db.execute(
        insert(role_permissions).values(
            [
                {"role_id": admin_role.id, "permission_id": perm_id}
                for perm_id in admin_permissions
            ]
        )
    )
    await db.execute(
        insert(role_permissions).values(
            [
                {"role_id": member_role.id, "permission_id": perm_id}
                for perm_id in member_permissions
            ]
        )
    )
    await db.flush()

    return {
        "permissions": {
            "read_users": read_users_perm,
            "write_users": write_users_perm,
            "delete_users": delete_users_perm,
        },
        "roles": {
            "admin": admin_role,
            "member": member_role,
        },
    }
```

---

## 4. Implement OAuth Tests (Priority: P1)

### 4.1 OAuth Unit Tests

**File:** `tests/unit/auth/test_oauth.py` (NEW)

```python
"""Unit tests for OAuth2 authentication."""

import pytest

from app.core.auth.oauth import (
    GoogleOAuthProvider,
    OAuthUserInfo,
    generate_state,
    get_available_providers,
    get_provider,
)


@pytest.mark.unit
class TestOAuthState:
    """Tests for OAuth state generation."""

    def test_generate_state_returns_string(self):
        """generate_state should return a random string."""
        state = generate_state()

        assert isinstance(state, str)
        assert len(state) > 20  # At least 20 chars

    def test_generate_state_unique(self):
        """generate_state should produce unique values."""
        state1 = generate_state()
        state2 = generate_state()

        assert state1 != state2

    def test_generate_state_url_safe(self):
        """generate_state should use URL-safe characters."""
        state = generate_state()

        # URL-safe means no +, /, = (those are base64 padding)
        assert "/" not in state or state.endswith("/")


@pytest.mark.unit
class TestGoogleOAuthProvider:
    """Tests for Google OAuth provider."""

    def test_provider_configured_with_env_vars(self):
        """GoogleOAuthProvider should read from settings."""
        provider = GoogleOAuthProvider()

        # Will be configured or not based on environment
        # For unit test, just verify the structure
        assert hasattr(provider, "client_id")
        assert hasattr(provider, "client_secret")
        assert hasattr(provider, "name")
        assert provider.name == "google"

    def test_authorize_url_has_required_params(self):
        """OAuth authorize URL should include required params."""
        provider = GoogleOAuthProvider()

        if not provider.is_configured:
            pytest.skip("Google OAuth not configured")

        url = provider.get_authorize_url(
            redirect_uri="http://localhost:3000/callback",
            state="test-state-123",
        )

        assert "client_id=" in url
        assert "redirect_uri=" in url
        assert "state=test-state-123" in url
        assert "scope=" in url

    def test_authorize_url_includes_google_specifics(self):
        """Google-specific params should be in authorize URL."""
        provider = GoogleOAuthProvider()

        if not provider.is_configured:
            pytest.skip("Google OAuth not configured")

        url = provider.get_authorize_url(
            redirect_uri="http://localhost:3000/callback",
            state="test-state-123",
        )

        assert "access_type=offline" in url
        assert "prompt=select_account" in url


@pytest.mark.unit
class TestOAuthUserInfo:
    """Tests for OAuth user info model."""

    def test_oauth_user_info_required_fields(self):
        """OAuthUserInfo should require email, name, provider, provider_id."""
        user_info = OAuthUserInfo(
            email="user@example.com",
            name="Test User",
            provider="google",
            provider_id="google-123",
        )

        assert user_info.email == "user@example.com"
        assert user_info.name == "Test User"
        assert user_info.provider == "google"
        assert user_info.provider_id == "google-123"
        assert user_info.picture is None

    def test_oauth_user_info_optional_picture(self):
        """OAuthUserInfo picture should be optional."""
        user_info = OAuthUserInfo(
            email="user@example.com",
            name="Test User",
            provider="google",
            provider_id="google-123",
            picture="https://example.com/pic.jpg",
        )

        assert user_info.picture == "https://example.com/pic.jpg"


@pytest.mark.unit
class TestProviderRegistry:
    """Tests for OAuth provider registry."""

    def test_get_provider_returns_none_for_unknown(self):
        """get_provider should return None for unknown providers."""
        provider = get_provider("unknown")

        assert provider is None

    def test_get_available_providers_returns_list(self):
        """get_available_providers should return list of configured providers."""
        providers = get_available_providers()

        assert isinstance(providers, list)
        # Might be empty if no providers configured, or include "google"
```

### 4.2 OAuth Integration Tests with Mocking

**File:** `tests/integration/auth/test_oauth_callback.py` (NEW)

```python
"""Integration tests for OAuth callback flow."""

from uuid import uuid4
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient

from app.core.auth.oauth import OAuthUserInfo


pytestmark = pytest.mark.integration


class TestOAuthCallbackFlow:
    """Tests for OAuth callback and user creation."""

    async def test_oauth_callback_creates_new_user(
        self,
        client: AsyncClient,
        db,
    ):
        """POST /auth/oauth/google/callback should create new user."""
        mock_user_info = OAuthUserInfo(
            email="oauth_user@example.com",
            name="OAuth User",
            provider="google",
            provider_id="google-unique-id-123",
        )

        # Mock the OAuth provider
        with patch("app.core.auth.oauth_routes.get_provider") as mock_get_provider:
            mock_provider = AsyncMock()
            mock_provider.exchange_code.return_value = {"access_token": "test-token"}
            mock_provider.get_user_info.return_value = mock_user_info
            mock_get_provider.return_value = mock_provider

            response = await client.post(
                "/api/v1/auth/oauth/google/callback",
                json={
                    "code": "auth-code-123",
                    "state": "state-123",
                },
            )

        # Should create user and return tokens
        assert response.status_code == 200
        data = response.json()
        assert "access_token" in data
        assert "refresh_token" in data
        assert data["user"]["email"] == "oauth_user@example.com"

    async def test_oauth_callback_returns_existing_user(
        self,
        client: AsyncClient,
        db,
    ):
        """OAuth callback should return existing OAuth user."""
        # First create a user
        response1 = await client.post(
            "/api/v1/auth/oauth/google/callback",
            json={
                "code": "auth-code-123",
                "state": "state-123",
            },
        )
        assert response1.status_code == 200
        user_id_1 = response1.json()["user"]["id"]

        # Call again with same OAuth ID
        response2 = await client.post(
            "/api/v1/auth/oauth/google/callback",
            json={
                "code": "auth-code-123",
                "state": "state-123",
            },
        )

        # Should return same user
        assert response2.status_code == 200
        user_id_2 = response2.json()["user"]["id"]
        assert user_id_1 == user_id_2

    async def test_oauth_callback_invalid_state(
        self,
        client: AsyncClient,
    ):
        """OAuth callback should reject invalid state."""
        response = await client.post(
            "/api/v1/auth/oauth/google/callback",
            json={
                "code": "auth-code-123",
                "state": "wrong-state",
            },
        )

        # Should reject
        assert response.status_code == 401
```

---

## 5. Implement RBAC Tests (Priority: P1)

### 5.1 Permission Checker Tests

**File:** `tests/unit/permissions/test_checker.py` (NEW)

```python
"""Unit tests for permission checking logic."""

from uuid import uuid4

import pytest

from app.core.permissions.checker import PermissionChecker
from app.core.permissions.models import Permission, Role
from tests.factories.permission import PermissionFactory
from tests.factories.role import RoleFactory


@pytest.mark.unit
class TestPermissionChecker:
    """Tests for PermissionChecker service."""

    async def test_get_user_roles_empty(self, db):
        """get_user_roles should return empty list for user with no roles."""
        user_id = uuid4()
        tenant_id = uuid4()

        checker = PermissionChecker(db)
        roles = await checker.get_user_roles(user_id, tenant_id)

        assert roles == []

    async def test_has_permission_granted(self, db, roles_and_permissions):
        """has_permission should return True for granted permission."""
        from app.core.permissions.models import UserRole

        # Setup
        admin_user = roles_and_permissions["roles"]["admin"]
        read_perm = roles_and_permissions["permissions"]["read_users"]
        user_id = uuid4()

        # Assign role to user
        user_role = UserRole(user_id=user_id, role_id=admin_user.id)
        db.add(user_role)
        await db.flush()

        # Check
        checker = PermissionChecker(db)
        result = await checker.has_permission(
            user_id,
            admin_user.tenant_id,
            "users",
            "read",
        )

        assert result is True

    async def test_has_permission_denied(self, db, roles_and_permissions):
        """has_permission should return False for denied permission."""
        from app.core.permissions.models import UserRole

        # Setup: member role only has read permission
        member_role = roles_and_permissions["roles"]["member"]
        user_id = uuid4()

        # Assign role to user
        user_role = UserRole(user_id=user_id, role_id=member_role.id)
        db.add(user_role)
        await db.flush()

        # Check
        checker = PermissionChecker(db)
        result = await checker.has_permission(
            user_id,
            member_role.tenant_id,
            "users",
            "delete",  # Member doesn't have this
        )

        assert result is False

    async def test_has_any_permission_one_match(self, db, roles_and_permissions):
        """has_any_permission should return True if any permission matches."""
        from app.core.permissions.models import UserRole

        admin_role = roles_and_permissions["roles"]["admin"]
        user_id = uuid4()

        user_role = UserRole(user_id=user_id, role_id=admin_role.id)
        db.add(user_role)
        await db.flush()

        checker = PermissionChecker(db)
        result = await checker.has_any_permission(
            user_id,
            admin_role.tenant_id,
            [
                ("users", "delete"),  # Has this
                ("users", "manage"),   # Doesn't have this
            ],
        )

        assert result is True

    async def test_has_all_permissions_all_match(self, db, roles_and_permissions):
        """has_all_permissions should return True if all permissions match."""
        from app.core.permissions.models import UserRole

        admin_role = roles_and_permissions["roles"]["admin"]
        user_id = uuid4()

        user_role = UserRole(user_id=user_id, role_id=admin_role.id)
        db.add(user_role)
        await db.flush()

        checker = PermissionChecker(db)
        result = await checker.has_all_permissions(
            user_id,
            admin_role.tenant_id,
            [
                ("users", "read"),
                ("users", "write"),
                ("users", "delete"),
            ],
        )

        assert result is True

    async def test_has_all_permissions_one_missing(self, db, roles_and_permissions):
        """has_all_permissions should return False if any permission missing."""
        from app.core.permissions.models import UserRole

        member_role = roles_and_permissions["roles"]["member"]
        user_id = uuid4()

        user_role = UserRole(user_id=user_id, role_id=member_role.id)
        db.add(user_role)
        await db.flush()

        checker = PermissionChecker(db)
        result = await checker.has_all_permissions(
            user_id,
            member_role.tenant_id,
            [
                ("users", "read"),   # Has this
                ("users", "delete"),  # Doesn't have
            ],
        )

        assert result is False
```

---

## 6. Implement Multi-Tenancy Tests (Priority: P1)

### 6.1 Multi-Tenant Isolation Tests

**File:** `tests/integration/multitenancy/test_tenant_isolation.py` (NEW)

```python
"""Integration tests for multi-tenant isolation."""

import pytest
from httpx import AsyncClient
from uuid import uuid4

from app.modules.tenants.models import Tenant
from app.modules.users.models import User
from app.core.auth.backend import hash_password


pytestmark = pytest.mark.integration


class TestTenantDataIsolation:
    """Tests for tenant-level data isolation."""

    async def test_user_cannot_see_other_tenant_users(self, db, client: AsyncClient):
        """User from Tenant A should not see users from Tenant B."""
        # Create two tenants
        tenant_a = Tenant(name="Tenant A", slug="tenant-a")
        tenant_b = Tenant(name="Tenant B", slug="tenant-b")
        db.add_all([tenant_a, tenant_b])
        await db.flush()

        # Create users in each tenant
        user_a = User(
            email="user-a@example.com",
            password_hash=hash_password("password123"),
            full_name="User A",
            tenant_id=tenant_a.id,
            is_superuser=True,
        )
        user_b = User(
            email="user-b@example.com",
            password_hash=hash_password("password123"),
            full_name="User B",
            tenant_id=tenant_b.id,
            is_superuser=True,
        )
        db.add_all([user_a, user_b])
        await db.flush()

        # Create tokens for user_a
        from app.core.auth.backend import (
            create_access_token,
        )

        access_token_a = create_access_token(user_a.id, tenant_a.id)

        # User A tries to list users
        response = await client.get(
            "/api/v1/users",
            headers={"Authorization": f"Bearer {access_token_a}"},
        )

        assert response.status_code == 200
        users = response.json()["items"]

        # Should only see User A, not User B
        emails = [u["email"] for u in users]
        assert "user-a@example.com" in emails
        assert "user-b@example.com" not in emails

    async def test_refresh_token_bound_to_tenant(self, db, client: AsyncClient):
        """Refresh token should be bound to tenant."""
        from app.modules.users.models import RefreshToken
        from app.core.auth.backend import (
            create_access_token,
            create_refresh_token,
            hash_token,
            get_token_expiration,
        )

        # Create two tenants and users
        tenant_a = Tenant(name="Tenant A", slug="tenant-a")
        tenant_b = Tenant(name="Tenant B", slug="tenant-b")
        db.add_all([tenant_a, tenant_b])
        await db.flush()

        user_a = User(
            email="user-a@example.com",
            password_hash=hash_password("password123"),
            full_name="User A",
            tenant_id=tenant_a.id,
            is_active=True,
        )
        user_b = User(
            email="user-b@example.com",
            password_hash=hash_password("password123"),
            full_name="User B",
            tenant_id=tenant_b.id,
            is_active=True,
        )
        db.add_all([user_a, user_b])
        await db.flush()

        # Create refresh token for user_a
        refresh_token_str = create_refresh_token(user_a.id, tenant_a.id)
        refresh_token = RefreshToken(
            user_id=user_a.id,
            token_hash=hash_token(refresh_token_str),
            expires_at=get_token_expiration().isoformat(),
        )
        db.add(refresh_token)
        await db.flush()

        # User B should not be able to use User A's refresh token
        # (This test verifies the token is tied to tenant_a through user_a)
        response = await client.post(
            "/api/v1/auth/refresh",
            json={"refresh_token": refresh_token_str},
        )

        # Token should work (it's valid), and should return tokens for user_a's tenant
        assert response.status_code == 200
        data = response.json()

        # Verify the new token is for tenant_a
        from app.core.auth.backend import decode_token

        decoded = decode_token(data["access_token"])
        assert decoded.tenant_id == tenant_a.id
```

---

## 7. Implementation Checklist

Use this checklist to track test implementation:

```markdown
## Test Implementation Checklist

### Phase 1: Infrastructure (Week 1)
- [ ] Fix engine fixture scope (2h)
- [ ] Remove event_loop fixture (1h)
- [ ] Add test markers to all tests (2h)
- [ ] Run: `pytest -m unit` - should pass all 16
- [ ] Run: `pytest -m integration` - should pass all 12

### Phase 2: Factories (Week 1)
- [ ] Create PermissionFactory (2h)
- [ ] Create RoleFactory (2h)
- [ ] Create UserRoleFactory (1h)
- [ ] Update __init__.py (30m)
- [ ] Test factories work correctly (1h)

### Phase 3: Enhanced Fixtures (Week 1)
- [ ] Add admin_user_with_tokens fixture (2h)
- [ ] Add regular_user_with_tokens fixture (2h)
- [ ] Add authenticated_client fixture (1h)
- [ ] Add roles_and_permissions fixture (3h)
- [ ] Test fixtures work (1h)

### Phase 4: OAuth Tests (Week 2-3)
- [ ] Implement OAuth unit tests (4h)
  - [ ] State generation
  - [ ] Provider configuration
  - [ ] Authorize URL generation
- [ ] Implement OAuth integration tests (6h)
  - [ ] New user creation
  - [ ] Existing user return
  - [ ] State validation
  - [ ] Error handling
- [ ] Test coverage: 8+ tests, >80% lines covered

### Phase 5: RBAC Tests (Week 2)
- [ ] Implement PermissionChecker tests (8h)
  - [ ] get_user_roles
  - [ ] has_permission (granted/denied)
  - [ ] has_any_permission
  - [ ] has_all_permissions
  - [ ] Wildcard permissions
- [ ] Implement decorator tests (6h)
  - [ ] Route protection
  - [ ] Error responses
  - [ ] Superuser bypass
- [ ] Test coverage: 12+ tests, >85% lines covered

### Phase 6: Multi-Tenancy Tests (Week 2)
- [ ] Implement tenant isolation tests (8h)
  - [ ] Cross-tenant access prevention
  - [ ] User isolation
  - [ ] Token binding
  - [ ] Query filtering
- [ ] Test coverage: 6+ tests, >80% lines covered

### Phase 7: Auth Service Tests (Week 3)
- [ ] Register endpoint (4h)
- [ ] Login endpoint (4h)
- [ ] Token refresh (3h)
- [ ] Logout (2h)
- [ ] Test coverage: 15+ tests, >85% lines covered

### Phase 8: User Service Tests (Week 3)
- [ ] CRUD operations (6h)
- [ ] OAuth user operations (4h)
- [ ] Pagination (2h)
- [ ] Test coverage: 10+ tests, >85% lines covered

### Phase 9: Error Handling (Week 4)
- [ ] Edge cases (6h)
- [ ] Boundary conditions (4h)
- [ ] Concurrent operations (4h)
- [ ] Security scenarios (6h)
- [ ] Test coverage: 15+ tests, >90% lines covered
```

---

## 8. Running Tests During Development

```bash
# Fix infrastructure (Run after making changes)
pytest tests/conftest.py -v  # Verify fixtures work

# Run specific test category
pytest -m unit -v             # All unit tests
pytest -m integration -v      # All integration tests

# Run specific factory tests
pytest tests/factories/ -v    # Verify factories work

# Run with coverage
pytest --cov=src --cov-report=term-missing

# Watch mode (requires pytest-watch)
ptw -- -m unit

# Run tests that failed last time
pytest --lf

# Run only tests with "oauth" in name
pytest -k oauth -v
```

---

## 9. Important Notes

1. **Async Fixtures:** All fixtures that touch the database must be `async def`
2. **Session Management:** Always `await db.flush()` after adding objects to ensure they have IDs
3. **Token Generation:** Use real token functions, not mocks, for integration tests
4. **Mocking:** Mock external services (OAuth providers, email, etc.) but use real database for data layer
5. **Isolation:** Each test should be independent - no shared state between tests
6. **Cleanup:** Transaction rollback handles cleanup automatically

---

## 10. Common Pitfalls to Avoid

```python
# ❌ DON'T: Use blocking sync code in async fixtures
@pytest.fixture
async def db(engine):
    session = engine.get_session()  # ❌ WRONG - blocking
    yield session

# ✅ DO: Use async operations
@pytest.fixture
async def db(engine):
    async with AsyncSession(engine) as session:  # ✅ CORRECT
        yield session

# ❌ DON'T: Forget to flush after creating objects
user = User(email="test@example.com", ...)
db.add(user)
# user.id is None here! Need to flush first

# ✅ DO: Flush to get the ID
user = User(email="test@example.com", ...)
db.add(user)
await db.flush()  # Now user.id is set

# ❌ DON'T: Mix sync and async in test
def test_something():
    response = client.get("/api/...")  # ❌ Can't use sync client in async test

# ✅ DO: Use async all the way
async def test_something():
    response = await client.get("/api/...")  # ✅ Use async client
```

