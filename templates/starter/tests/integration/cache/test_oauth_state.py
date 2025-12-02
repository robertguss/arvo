"""Integration tests for OAuth state storage."""

import pytest

from app.core.cache.oauth_state import (
    OAuthStateData,
    get_oauth_state,
    store_oauth_state,
    verify_oauth_state,
    _oauth_cache,
)
from app.core.cache.redis import RedisPoolHolder


@pytest.fixture(autouse=True)
async def reset_redis_pool():
    """Reset Redis pool before each test to avoid event loop issues."""
    RedisPoolHolder.pool = None
    yield
    # Clean up test keys
    try:
        from app.core.cache.redis import redis_client

        async with redis_client() as client:
            keys = await client.keys("oauth:state:*")
            if keys:
                await client.delete(*keys)
    except Exception:
        pass
    finally:
        RedisPoolHolder.pool = None


class TestStoreOAuthState:
    """Tests for store_oauth_state function."""

    @pytest.mark.asyncio
    async def test_store_oauth_state_success(self):
        """Verify state is stored and can be retrieved."""
        state = "test-state-123"
        data: OAuthStateData = {
            "provider": "google",
            "redirect_uri": "http://localhost/callback",
        }

        await store_oauth_state(state, data)

        # Verify it was stored
        result = await _oauth_cache.get_json(state)
        assert result is not None
        assert result["provider"] == "google"
        assert result["redirect_uri"] == "http://localhost/callback"


class TestGetOAuthState:
    """Tests for get_oauth_state function."""

    @pytest.mark.asyncio
    async def test_get_oauth_state_found(self):
        """Verify stored state is retrieved successfully."""
        state = "test-state-get-1"
        data: OAuthStateData = {
            "provider": "github",
            "redirect_uri": "http://localhost/github/callback",
        }

        await store_oauth_state(state, data)
        result = await get_oauth_state(state)

        assert result is not None
        assert result["provider"] == "github"
        assert result["redirect_uri"] == "http://localhost/github/callback"

    @pytest.mark.asyncio
    async def test_get_oauth_state_deleted_after_retrieval(self):
        """Verify state is deleted after first retrieval (one-time use)."""
        state = "test-state-get-2"
        data: OAuthStateData = {
            "provider": "google",
            "redirect_uri": "http://localhost/callback",
        }

        await store_oauth_state(state, data)

        # First retrieval should succeed
        result1 = await get_oauth_state(state)
        assert result1 is not None

        # Second retrieval should return None (already deleted)
        result2 = await get_oauth_state(state)
        assert result2 is None

    @pytest.mark.asyncio
    async def test_get_oauth_state_not_found(self):
        """Verify None is returned for non-existent state."""
        result = await get_oauth_state("nonexistent-state-12345")

        assert result is None

    @pytest.mark.asyncio
    async def test_get_oauth_state_missing_provider(self):
        """Verify None is returned when provider is missing."""
        state = "test-state-missing-provider"

        # Store invalid data directly
        await _oauth_cache.set_json(state, {"redirect_uri": "http://localhost"})

        result = await get_oauth_state(state)

        assert result is None

    @pytest.mark.asyncio
    async def test_get_oauth_state_missing_redirect_uri(self):
        """Verify None is returned when redirect_uri is missing."""
        state = "test-state-missing-redirect"

        # Store invalid data directly
        await _oauth_cache.set_json(state, {"provider": "google"})

        result = await get_oauth_state(state)

        assert result is None


class TestVerifyOAuthState:
    """Tests for verify_oauth_state function."""

    @pytest.mark.asyncio
    async def test_verify_oauth_state_valid(self):
        """Verify state is valid when provider matches."""
        state = "test-state-verify-1"
        data: OAuthStateData = {
            "provider": "google",
            "redirect_uri": "http://localhost/callback",
        }

        await store_oauth_state(state, data)
        result = await verify_oauth_state(state, "google")

        assert result is not None
        assert result["provider"] == "google"
        assert result["redirect_uri"] == "http://localhost/callback"

    @pytest.mark.asyncio
    async def test_verify_oauth_state_not_found(self):
        """Verify None is returned for non-existent state."""
        result = await verify_oauth_state("nonexistent-state-xyz", "google")

        assert result is None

    @pytest.mark.asyncio
    async def test_verify_oauth_state_provider_mismatch(self):
        """Verify None is returned when provider doesn't match."""
        state = "test-state-verify-2"
        data: OAuthStateData = {
            "provider": "google",
            "redirect_uri": "http://localhost/callback",
        }

        await store_oauth_state(state, data)
        result = await verify_oauth_state(state, "github")  # Wrong provider

        assert result is None
