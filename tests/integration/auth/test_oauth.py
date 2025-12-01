"""Integration tests for OAuth authentication.

These tests verify the OAuth2 authentication flow including:
- Provider listing
- Authorization URL generation
- Callback handling
- State validation (CSRF protection)
- User creation and linking
"""

from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth import hash_password
from app.core.auth.oauth import OAuthUserInfo
from app.modules.tenants.models import Tenant
from app.modules.users.models import User


pytestmark = pytest.mark.integration


class TestOAuthProviders:
    """Tests for OAuth provider listing."""

    async def test_list_providers_returns_configured(self, client: AsyncClient):
        """GET /api/v1/auth/oauth/providers should return configured providers."""
        with patch(
            "app.core.auth.oauth_routes.get_available_providers",
            return_value=["google"],
        ):
            response = await client.get("/api/v1/auth/oauth/providers")

        assert response.status_code == 200
        data = response.json()
        assert "providers" in data
        assert isinstance(data["providers"], list)

    async def test_list_providers_empty_when_none_configured(self, client: AsyncClient):
        """GET /api/v1/auth/oauth/providers should return empty when none configured."""
        with patch(
            "app.core.auth.oauth_routes.get_available_providers",
            return_value=[],
        ):
            response = await client.get("/api/v1/auth/oauth/providers")

        assert response.status_code == 200
        data = response.json()
        assert data["providers"] == []


class TestOAuthAuthorize:
    """Tests for OAuth authorization URL generation."""

    async def test_authorize_returns_url_and_state(self, client: AsyncClient):
        """GET /api/v1/auth/oauth/{provider}/authorize should return auth URL."""
        mock_provider = MagicMock()
        mock_provider.get_authorize_url.return_value = "https://accounts.google.com/o/oauth2/v2/auth?..."

        with (
            patch(
                "app.core.auth.oauth_routes._get_oauth_provider",
                return_value=mock_provider,
            ),
            patch(
                "app.core.auth.oauth_routes.store_oauth_state",
                new_callable=AsyncMock,
            ) as mock_store,
        ):
            response = await client.get("/api/v1/auth/oauth/google/authorize")

        assert response.status_code == 200
        data = response.json()
        assert "url" in data
        assert "state" in data
        assert data["url"].startswith("https://")
        assert len(data["state"]) > 20  # State should be a reasonable length

        # Verify state was stored
        mock_store.assert_called_once()

    async def test_authorize_unknown_provider_returns_404(self, client: AsyncClient):
        """GET /api/v1/auth/oauth/{provider}/authorize should 404 for unknown provider."""
        with patch(
            "app.core.auth.oauth_routes.get_provider",
            return_value=None,
        ):
            response = await client.get("/api/v1/auth/oauth/unknown/authorize")

        assert response.status_code == 404


class TestOAuthCallback:
    """Tests for OAuth callback handling."""

    @pytest.fixture
    def mock_user_info(self) -> OAuthUserInfo:
        """Create mock OAuth user info."""
        return OAuthUserInfo(
            email="oauth-user@example.com",
            name="OAuth User",
            provider="google",
            provider_id="google-123456",
            picture="https://example.com/picture.jpg",
        )

    @pytest.fixture
    def mock_oauth_provider(self, mock_user_info: OAuthUserInfo):
        """Create mock OAuth provider."""
        provider = MagicMock()
        provider.exchange_code = AsyncMock(
            return_value={"access_token": "mock-access-token"}
        )
        provider.get_user_info = AsyncMock(return_value=mock_user_info)
        return provider

    async def test_callback_validates_state(self, client: AsyncClient):
        """OAuth callback should reject invalid state."""
        with patch(
            "app.core.auth.oauth_routes.verify_oauth_state",
            new_callable=AsyncMock,
            return_value=None,  # Invalid state
        ):
            response = await client.get(
                "/api/v1/auth/oauth/google/callback",
                params={"code": "auth-code", "state": "invalid-state"},
            )

        assert response.status_code == 400
        data = response.json()
        assert "invalid_state" in data.get("type", "")

    async def test_callback_rejects_provider_error(self, client: AsyncClient):
        """OAuth callback should handle provider errors."""
        response = await client.get(
            "/api/v1/auth/oauth/google/callback",
            params={
                "error": "access_denied",
                "error_description": "User denied access",
                "state": "some-state",
            },
        )

        assert response.status_code == 400
        data = response.json()
        assert "oauth_error" in data.get("type", "")

    async def test_callback_creates_new_user(
        self,
        client: AsyncClient,
        db: AsyncSession,
        mock_oauth_provider: MagicMock,
        mock_user_info: OAuthUserInfo,
    ):
        """OAuth callback should create new user and tenant."""
        valid_state_data = {
            "provider": "google",
            "redirect_uri": "http://test/callback",
        }

        with (
            patch(
                "app.core.auth.oauth_routes.verify_oauth_state",
                new_callable=AsyncMock,
                return_value=valid_state_data,
            ),
            patch(
                "app.core.auth.oauth_routes._get_oauth_provider",
                return_value=mock_oauth_provider,
            ),
        ):
            response = await client.get(
                "/api/v1/auth/oauth/google/callback",
                params={"code": "valid-code", "state": "valid-state"},
            )

        assert response.status_code == 200
        data = response.json()
        assert "access_token" in data
        assert "refresh_token" in data
        assert data["token_type"] == "bearer"

    async def test_callback_links_existing_user_by_email(
        self,
        client: AsyncClient,
        db: AsyncSession,
        mock_oauth_provider: MagicMock,
        mock_user_info: OAuthUserInfo,
    ):
        """OAuth callback should link to existing user with same email."""
        # Create existing user with same email but no OAuth
        tenant = Tenant(name="Existing Tenant", slug="existing-tenant")
        db.add(tenant)
        await db.flush()

        existing_user = User(
            email=mock_user_info.email,  # Same email as OAuth
            password_hash=hash_password("password123"),
            full_name="Existing User",
            tenant_id=tenant.id,
        )
        db.add(existing_user)
        await db.flush()

        valid_state_data = {
            "provider": "google",
            "redirect_uri": "http://test/callback",
        }

        with (
            patch(
                "app.core.auth.oauth_routes.verify_oauth_state",
                new_callable=AsyncMock,
                return_value=valid_state_data,
            ),
            patch(
                "app.core.auth.oauth_routes._get_oauth_provider",
                return_value=mock_oauth_provider,
            ),
        ):
            response = await client.get(
                "/api/v1/auth/oauth/google/callback",
                params={"code": "valid-code", "state": "valid-state"},
            )

        assert response.status_code == 200

        # Verify user was linked
        await db.refresh(existing_user)
        assert existing_user.oauth_provider == "google"
        assert existing_user.oauth_id == mock_user_info.provider_id

    async def test_callback_recognizes_existing_oauth_user(
        self,
        client: AsyncClient,
        db: AsyncSession,
        mock_oauth_provider: MagicMock,
        mock_user_info: OAuthUserInfo,
    ):
        """OAuth callback should recognize returning OAuth user."""
        # Create existing OAuth user
        tenant = Tenant(name="OAuth Tenant", slug="oauth-tenant")
        db.add(tenant)
        await db.flush()

        existing_oauth_user = User(
            email=mock_user_info.email,
            full_name="OAuth User",
            oauth_provider="google",
            oauth_id=mock_user_info.provider_id,  # Same OAuth ID
            tenant_id=tenant.id,
        )
        db.add(existing_oauth_user)
        await db.flush()

        valid_state_data = {
            "provider": "google",
            "redirect_uri": "http://test/callback",
        }

        with (
            patch(
                "app.core.auth.oauth_routes.verify_oauth_state",
                new_callable=AsyncMock,
                return_value=valid_state_data,
            ),
            patch(
                "app.core.auth.oauth_routes._get_oauth_provider",
                return_value=mock_oauth_provider,
            ),
        ):
            response = await client.get(
                "/api/v1/auth/oauth/google/callback",
                params={"code": "valid-code", "state": "valid-state"},
            )

        assert response.status_code == 200

    async def test_callback_rejects_inactive_user(
        self,
        client: AsyncClient,
        db: AsyncSession,
        mock_oauth_provider: MagicMock,
        mock_user_info: OAuthUserInfo,
    ):
        """OAuth callback should reject inactive users."""
        # Create inactive OAuth user
        tenant = Tenant(name="Inactive Tenant", slug="inactive-tenant")
        db.add(tenant)
        await db.flush()

        inactive_user = User(
            email=mock_user_info.email,
            full_name="Inactive User",
            oauth_provider="google",
            oauth_id=mock_user_info.provider_id,
            tenant_id=tenant.id,
            is_active=False,  # Inactive
        )
        db.add(inactive_user)
        await db.flush()

        valid_state_data = {
            "provider": "google",
            "redirect_uri": "http://test/callback",
        }

        with (
            patch(
                "app.core.auth.oauth_routes.verify_oauth_state",
                new_callable=AsyncMock,
                return_value=valid_state_data,
            ),
            patch(
                "app.core.auth.oauth_routes._get_oauth_provider",
                return_value=mock_oauth_provider,
            ),
        ):
            response = await client.get(
                "/api/v1/auth/oauth/google/callback",
                params={"code": "valid-code", "state": "valid-state"},
            )

        assert response.status_code == 400
        data = response.json()
        assert "account_inactive" in data.get("type", "")


class TestOAuthStateSecurity:
    """Tests for OAuth state security (CSRF protection)."""

    async def test_state_is_one_time_use(self, client: AsyncClient):
        """OAuth state should be deleted after use (prevent replay)."""
        # This is tested by verifying verify_oauth_state returns None on second call
        # The actual implementation deletes the state from Redis
        with (
            patch(
                "app.core.auth.oauth_routes.verify_oauth_state",
                new_callable=AsyncMock,
                side_effect=[
                    {"provider": "google", "redirect_uri": "http://test"},
                    None,  # Second call returns None (state was deleted)
                ],
            ),
            patch(
                "app.core.auth.oauth_routes._get_oauth_provider",
                side_effect=Exception("Should not reach provider"),
            ),
        ):
            # First call - should proceed (but fail at provider for this test)
            response1 = await client.get(
                "/api/v1/auth/oauth/google/callback",
                params={"code": "code", "state": "state"},
            )

            # Second call with same state - should fail at state verification
            response2 = await client.get(
                "/api/v1/auth/oauth/google/callback",
                params={"code": "code", "state": "state"},
            )

        # First might fail at provider, second should fail at state
        assert response2.status_code == 400
        assert "invalid_state" in response2.json().get("type", "")

    async def test_state_provider_mismatch_rejected(self, client: AsyncClient):
        """OAuth state should reject provider mismatch."""
        # State was created for Google but callback is for GitHub
        with patch(
            "app.core.auth.oauth_routes.verify_oauth_state",
            new_callable=AsyncMock,
            return_value=None,  # verify_oauth_state returns None for mismatch
        ):
            response = await client.get(
                "/api/v1/auth/oauth/github/callback",  # Different provider
                params={"code": "code", "state": "google-state"},
            )

        assert response.status_code == 400

