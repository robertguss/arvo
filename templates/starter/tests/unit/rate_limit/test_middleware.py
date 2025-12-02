"""Unit tests for rate limit middleware."""

from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest

from app.core.rate_limit.backend import RateLimitResult
from app.core.rate_limit.middleware import RateLimitMiddleware


def make_mock_request(
    path="/api/test",
    user_id=None,
    client_host="192.168.1.1",
    forwarded_for=None,
):
    """Create a mock Request for testing."""
    request = MagicMock()
    request.url = MagicMock()
    request.url.path = path
    request.state = MagicMock()

    if user_id:
        request.state.user_id = user_id
    else:
        del request.state.user_id

    if client_host:
        request.client = MagicMock()
        request.client.host = client_host
    else:
        request.client = None

    request.headers = MagicMock()
    request.headers.get = MagicMock(return_value=forwarded_for)

    return request


class TestRateLimitMiddlewareGetIdentifier:
    """Tests for _get_identifier method."""

    def test_authenticated_user_uses_user_id(self):
        """Verify user_id is used for authenticated users."""
        middleware = RateLimitMiddleware.__new__(RateLimitMiddleware)
        user_id = uuid4()
        request = make_mock_request(user_id=user_id)

        result = middleware._get_identifier(request)

        assert result == f"user:{user_id}"

    def test_unauthenticated_uses_direct_ip(self):
        """Verify direct client IP is used for unauthenticated users."""
        middleware = RateLimitMiddleware.__new__(RateLimitMiddleware)
        request = make_mock_request(client_host="10.0.0.50")

        result = middleware._get_identifier(request)

        assert result == "ip:10.0.0.50"

    def test_unknown_client_returns_unknown(self):
        """Verify 'unknown' used when client is None."""
        middleware = RateLimitMiddleware.__new__(RateLimitMiddleware)
        request = make_mock_request(client_host=None)

        result = middleware._get_identifier(request)

        assert result == "ip:unknown"

    def test_trusted_proxy_uses_forwarded_for(self):
        """Verify X-Forwarded-For is used for trusted proxies."""
        middleware = RateLimitMiddleware.__new__(RateLimitMiddleware)
        request = make_mock_request(
            client_host="10.0.0.1",
            forwarded_for="203.0.113.100, 10.0.0.1",
        )

        with patch("app.core.rate_limit.middleware.settings") as mock_settings:
            mock_settings.trusted_proxies = {"10.0.0.1"}

            result = middleware._get_identifier(request)

            assert result == "ip:203.0.113.100"

    def test_untrusted_proxy_ignores_forwarded_for(self):
        """Verify X-Forwarded-For is ignored for untrusted sources."""
        middleware = RateLimitMiddleware.__new__(RateLimitMiddleware)
        request = make_mock_request(
            client_host="192.168.1.100",
            forwarded_for="spoofed.ip.address",
        )

        with patch("app.core.rate_limit.middleware.settings") as mock_settings:
            mock_settings.trusted_proxies = {"10.0.0.1"}  # Different IP

            result = middleware._get_identifier(request)

            # Should use direct IP, not spoofed X-Forwarded-For
            assert result == "ip:192.168.1.100"


class TestRateLimitMiddlewareDispatch:
    """Tests for dispatch method."""

    @pytest.mark.asyncio
    async def test_excluded_path_skips_rate_limit(self):
        """Verify excluded paths are not rate limited."""
        middleware = RateLimitMiddleware.__new__(RateLimitMiddleware)
        middleware.app = AsyncMock()
        request = make_mock_request(path="/health/live")
        mock_response = MagicMock()
        call_next = AsyncMock(return_value=mock_response)

        with patch(
            "app.core.rate_limit.middleware.rate_limiter"
        ) as mock_limiter:
            result = await middleware.dispatch(request, call_next)

            mock_limiter.is_allowed.assert_not_called()
            call_next.assert_awaited_once_with(request)
            assert result == mock_response

    @pytest.mark.asyncio
    async def test_allowed_request_adds_headers(self):
        """Verify allowed requests get rate limit headers."""
        middleware = RateLimitMiddleware.__new__(RateLimitMiddleware)
        middleware.app = AsyncMock()
        request = make_mock_request(path="/api/users")

        mock_response = MagicMock()
        mock_response.headers = {}
        call_next = AsyncMock(return_value=mock_response)

        rate_result = RateLimitResult(
            allowed=True,
            limit=100,
            remaining=99,
            reset_time=1234567890,
        )

        with (
            patch(
                "app.core.rate_limit.middleware.rate_limiter"
            ) as mock_limiter,
            patch("app.core.rate_limit.middleware.settings") as mock_settings,
        ):
            mock_limiter.is_allowed = AsyncMock(return_value=rate_result)
            mock_settings.rate_limit_requests = 100
            mock_settings.rate_limit_window = 60
            mock_settings.trusted_proxies = set()

            result = await middleware.dispatch(request, call_next)

            assert result == mock_response
            assert result.headers["X-RateLimit-Limit"] == "100"
            assert result.headers["X-RateLimit-Remaining"] == "99"
            assert result.headers["X-RateLimit-Reset"] == "1234567890"

    @pytest.mark.asyncio
    async def test_rate_limited_returns_429(self):
        """Verify rate limited requests return 429."""
        middleware = RateLimitMiddleware.__new__(RateLimitMiddleware)
        middleware.app = AsyncMock()
        request = make_mock_request(path="/api/users")
        call_next = AsyncMock()

        rate_result = RateLimitResult(
            allowed=False,
            limit=100,
            remaining=0,
            reset_time=1234567890,
            retry_after=60,
        )

        with (
            patch(
                "app.core.rate_limit.middleware.rate_limiter"
            ) as mock_limiter,
            patch("app.core.rate_limit.middleware.settings") as mock_settings,
        ):
            mock_limiter.is_allowed = AsyncMock(return_value=rate_result)
            mock_settings.rate_limit_requests = 100
            mock_settings.rate_limit_window = 60
            mock_settings.api_docs_base_url = "https://api.example.com"
            mock_settings.trusted_proxies = set()

            result = await middleware.dispatch(request, call_next)

            assert result.status_code == 429
            call_next.assert_not_awaited()
