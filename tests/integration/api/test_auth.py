"""Integration tests for auth endpoints."""

import pytest
from httpx import AsyncClient

from app.core.auth import hash_password
from app.modules.tenants.models import Tenant
from app.modules.users.models import User


pytestmark = pytest.mark.integration


class TestRegistration:
    """Tests for user registration endpoint."""

    async def test_register_success(self, client: AsyncClient):
        """POST /api/v1/auth/register should create user and tenant."""
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "newuser@example.com",
                "password": "SecurePass123!",
                "full_name": "New User",
                "tenant_name": "New Company",
            },
        )

        assert response.status_code == 201
        data = response.json()
        assert "access_token" in data
        assert "refresh_token" in data
        assert data["user"]["email"] == "newuser@example.com"
        assert data["user"]["full_name"] == "New User"

    async def test_register_duplicate_email(self, client: AsyncClient, db):
        """POST /api/v1/auth/register should reject duplicate email."""
        # Create existing tenant and user
        tenant = Tenant(name="Existing", slug="existing")
        db.add(tenant)
        await db.flush()

        user = User(
            email="existing@example.com",
            password_hash=hash_password("SecurePass123!"),
            full_name="Existing User",
            tenant_id=tenant.id,
        )
        db.add(user)
        await db.flush()

        # Try to register with same email
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "existing@example.com",
                "password": "SecurePass123!",
                "full_name": "Another User",
                "tenant_name": "Another Company",
            },
        )

        assert response.status_code == 409
        data = response.json()
        assert "email" in data["type"] or "registration" in data["type"]

    async def test_register_weak_password(self, client: AsyncClient):
        """POST /api/v1/auth/register should reject weak password."""
        response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "newuser@example.com",
                "password": "short",  # Too short
                "full_name": "New User",
                "tenant_name": "New Company",
            },
        )

        assert response.status_code == 422


class TestLogin:
    """Tests for login endpoint."""

    async def test_login_success(self, client: AsyncClient, db):
        """POST /api/v1/auth/login should return tokens for valid credentials."""
        # Create user
        tenant = Tenant(name="Test", slug="test-login")
        db.add(tenant)
        await db.flush()

        user = User(
            email="login@example.com",
            password_hash=hash_password("SecurePass123!"),
            full_name="Login User",
            tenant_id=tenant.id,
        )
        db.add(user)
        await db.flush()

        response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": "login@example.com",
                "password": "SecurePass123!",
            },
        )

        assert response.status_code == 200
        data = response.json()
        assert "access_token" in data
        assert "refresh_token" in data
        assert data["token_type"] == "bearer"
        assert data["expires_in"] > 0

    async def test_login_wrong_password(self, client: AsyncClient, db):
        """POST /api/v1/auth/login should reject wrong password."""
        # Create user
        tenant = Tenant(name="Test", slug="test-wrong-pw")
        db.add(tenant)
        await db.flush()

        user = User(
            email="wrongpw@example.com",
            password_hash=hash_password("CorrectPass123!"),
            full_name="Test User",
            tenant_id=tenant.id,
        )
        db.add(user)
        await db.flush()

        response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": "wrongpw@example.com",
                "password": "WrongPass123!",
            },
        )

        assert response.status_code == 401

    async def test_login_nonexistent_user(self, client: AsyncClient):
        """POST /api/v1/auth/login should reject nonexistent user."""
        response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": "nonexistent@example.com",
                "password": "anypassword",
            },
        )

        assert response.status_code == 401

    async def test_login_inactive_user(self, client: AsyncClient, db):
        """POST /api/v1/auth/login should reject inactive user."""
        # Create inactive user
        tenant = Tenant(name="Test", slug="test-inactive")
        db.add(tenant)
        await db.flush()

        user = User(
            email="inactive@example.com",
            password_hash=hash_password("SecurePass123!"),
            full_name="Inactive User",
            tenant_id=tenant.id,
            is_active=False,
        )
        db.add(user)
        await db.flush()

        response = await client.post(
            "/api/v1/auth/login",
            json={
                "email": "inactive@example.com",
                "password": "SecurePass123!",
            },
        )

        assert response.status_code == 401


class TestTokenRefresh:
    """Tests for token refresh endpoint."""

    async def test_refresh_valid_token(self, client: AsyncClient):
        """POST /api/v1/auth/refresh should return new tokens."""
        # First register to get tokens
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "refresh@example.com",
                "password": "SecurePass123!",
                "full_name": "Refresh User",
                "tenant_name": "Refresh Company",
            },
        )
        assert register_response.status_code == 201
        refresh_token = register_response.json()["refresh_token"]

        # Use refresh token
        response = await client.post(
            "/api/v1/auth/refresh",
            json={"refresh_token": refresh_token},
        )

        assert response.status_code == 200
        data = response.json()
        assert "access_token" in data
        assert "refresh_token" in data
        # Old refresh token should be different
        assert data["refresh_token"] != refresh_token

    async def test_refresh_invalid_token(self, client: AsyncClient):
        """POST /api/v1/auth/refresh should reject invalid token."""
        response = await client.post(
            "/api/v1/auth/refresh",
            json={"refresh_token": "invalid-refresh-token"},
        )

        assert response.status_code == 401


class TestGetMe:
    """Tests for get current user endpoint."""

    async def test_get_me_authenticated(self, client: AsyncClient):
        """GET /api/v1/auth/me should return current user."""
        # Register to get tokens
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "getme@example.com",
                "password": "SecurePass123!",
                "full_name": "Get Me User",
                "tenant_name": "Get Me Company",
            },
        )
        assert register_response.status_code == 201, register_response.json()
        access_token = register_response.json()["access_token"]

        # Get current user
        response = await client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {access_token}"},
        )

        assert response.status_code == 200
        data = response.json()
        assert data["email"] == "getme@example.com"
        assert data["full_name"] == "Get Me User"

    async def test_get_me_unauthenticated(self, client: AsyncClient):
        """GET /api/v1/auth/me should reject unauthenticated request."""
        response = await client.get("/api/v1/auth/me")

        assert response.status_code == 401


class TestLogout:
    """Tests for logout endpoint."""

    async def test_logout_success(self, client: AsyncClient):
        """POST /api/v1/auth/logout should revoke refresh token."""
        # Register to get tokens
        register_response = await client.post(
            "/api/v1/auth/register",
            json={
                "email": "logout@example.com",
                "password": "SecurePass123!",
                "full_name": "Logout User",
                "tenant_name": "Logout Company",
            },
        )
        assert register_response.status_code == 201, register_response.json()
        refresh_token = register_response.json()["refresh_token"]

        # Logout
        response = await client.post(
            "/api/v1/auth/logout",
            json={"refresh_token": refresh_token},
        )

        assert response.status_code == 204

        # Try to use the revoked token
        refresh_response = await client.post(
            "/api/v1/auth/refresh",
            json={"refresh_token": refresh_token},
        )
        assert refresh_response.status_code == 401

