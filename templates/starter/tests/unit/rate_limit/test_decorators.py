"""Unit tests for rate limit decorator."""

from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest
from fastapi import Request
from starlette.responses import JSONResponse

from app.core.rate_limit.backend import RateLimitResult
from app.core.rate_limit.decorators import _get_default_identifier, rate_limit


def make_mock_request(
    user_id=None,
    client_host="192.168.1.1",
    forwarded_for=None,
    path="/api/test",
):
    """Create a mock Request object for testing."""
    request = MagicMock(spec=Request)
    request.state = MagicMock()

    if user_id:
        request.state.user_id = user_id
    else:
        # Ensure user_id attribute doesn't exist
        del request.state.user_id

    request.url = MagicMock()
    request.url.path = path

    request.headers = MagicMock()
    request.headers.get = MagicMock(return_value=forwarded_for)

    if client_host:
        request.client = MagicMock()
        request.client.host = client_host
    else:
        request.client = None

    return request


class TestGetDefaultIdentifier:
    """Tests for _get_default_identifier function."""

    def test_authenticated_user_returns_user_identifier(self):
        """Verify user ID is used for authenticated users."""
        user_id = uuid4()
        request = make_mock_request(user_id=user_id)

        result = _get_default_identifier(request)

        assert result == f"user:{user_id}"

    def test_x_forwarded_for_uses_first_ip(self):
        """Verify first IP from X-Forwarded-For is used."""
        request = make_mock_request(forwarded_for="10.0.0.1, 10.0.0.2, 10.0.0.3")

        result = _get_default_identifier(request)

        assert result == "ip:10.0.0.1"

    def test_direct_client_ip_used(self):
        """Verify direct client IP is used when no proxy."""
        request = make_mock_request(client_host="203.0.113.50")

        result = _get_default_identifier(request)

        assert result == "ip:203.0.113.50"

    def test_unknown_client_when_no_client_info(self):
        """Verify 'unknown' is used when client info is None."""
        request = make_mock_request(client_host=None)

        result = _get_default_identifier(request)

        assert result == "ip:unknown"


class TestRateLimitDecorator:
    """Tests for rate_limit decorator."""

    @pytest.mark.asyncio
    async def test_request_in_positional_args(self):
        """Verify decorator finds Request in positional args."""
        request = make_mock_request()
        mock_result = RateLimitResult(
            allowed=True, limit=100, remaining=99, reset_time=1234567890
        )

        @rate_limit(requests=100, window=60)
        async def endpoint(request: Request):
            return {"status": "ok"}

        with patch("app.core.rate_limit.decorators.rate_limiter") as mock_limiter:
            mock_limiter.is_allowed = AsyncMock(return_value=mock_result)

            result = await endpoint(request)

            assert result == {"status": "ok"}
            mock_limiter.is_allowed.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_request_in_kwargs(self):
        """Verify decorator finds Request in kwargs."""
        request = make_mock_request()
        mock_result = RateLimitResult(
            allowed=True, limit=100, remaining=99, reset_time=1234567890
        )

        @rate_limit(requests=100, window=60)
        async def endpoint(request: Request):
            return {"status": "ok"}

        with patch("app.core.rate_limit.decorators.rate_limiter") as mock_limiter:
            mock_limiter.is_allowed = AsyncMock(return_value=mock_result)

            result = await endpoint(request=request)

            assert result == {"status": "ok"}
            mock_limiter.is_allowed.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_no_request_skips_rate_limiting(self):
        """Verify decorator skips rate limiting when no Request found."""

        @rate_limit(requests=100, window=60)
        async def endpoint(data: dict):
            return {"received": data}

        with patch("app.core.rate_limit.decorators.rate_limiter") as mock_limiter:
            mock_limiter.is_allowed = AsyncMock()
            result = await endpoint({"key": "value"})

            assert result == {"received": {"key": "value"}}
            mock_limiter.is_allowed.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_custom_key_func(self):
        """Verify custom key_func is used for identifier."""
        request = make_mock_request()
        mock_result = RateLimitResult(
            allowed=True, limit=50, remaining=49, reset_time=1234567890
        )

        def custom_key(req: Request) -> str:
            return "custom:api_key_123"

        @rate_limit(requests=50, window=30, key_func=custom_key)
        async def endpoint(request: Request):
            return {"status": "ok"}

        with patch("app.core.rate_limit.decorators.rate_limiter") as mock_limiter:
            mock_limiter.is_allowed = AsyncMock(return_value=mock_result)

            await endpoint(request)

            mock_limiter.is_allowed.assert_awaited_once_with(
                identifier="custom:api_key_123",
                limit=50,
                window=30,
                endpoint="/api/test",
            )

    @pytest.mark.asyncio
    async def test_rate_limit_exceeded_returns_429(self):
        """Verify 429 response when rate limit exceeded."""
        request = make_mock_request()
        mock_result = RateLimitResult(
            allowed=False,
            limit=10,
            remaining=0,
            reset_time=1234567890,
            retry_after=60,
        )

        @rate_limit(requests=10, window=60)
        async def endpoint(request: Request):
            return {"status": "ok"}

        with patch("app.core.rate_limit.decorators.rate_limiter") as mock_limiter:
            mock_limiter.is_allowed = AsyncMock(return_value=mock_result)

            result = await endpoint(request)

            assert isinstance(result, JSONResponse)
            assert result.status_code == 429

    @pytest.mark.asyncio
    async def test_rate_limit_exceeded_response_headers(self):
        """Verify rate limit headers in 429 response."""
        request = make_mock_request()
        mock_result = RateLimitResult(
            allowed=False,
            limit=10,
            remaining=0,
            reset_time=1234567890,
            retry_after=45,
        )

        @rate_limit(requests=10, window=60)
        async def endpoint(request: Request):
            return {"status": "ok"}

        with patch("app.core.rate_limit.decorators.rate_limiter") as mock_limiter:
            mock_limiter.is_allowed = AsyncMock(return_value=mock_result)

            result = await endpoint(request)

            assert result.headers["X-RateLimit-Limit"] == "10"
            assert result.headers["X-RateLimit-Remaining"] == "0"
            assert result.headers["X-RateLimit-Reset"] == "1234567890"
            assert result.headers["Retry-After"] == "45"

    @pytest.mark.asyncio
    async def test_endpoint_path_passed_to_rate_limiter(self):
        """Verify endpoint path is passed to rate limiter."""
        request = make_mock_request(path="/api/v1/users")
        mock_result = RateLimitResult(
            allowed=True, limit=100, remaining=99, reset_time=1234567890
        )

        @rate_limit(requests=100, window=60)
        async def endpoint(request: Request):
            return {"status": "ok"}

        with patch("app.core.rate_limit.decorators.rate_limiter") as mock_limiter:
            mock_limiter.is_allowed = AsyncMock(return_value=mock_result)

            await endpoint(request)

            mock_limiter.is_allowed.assert_awaited_once_with(
                identifier="ip:192.168.1.1",
                limit=100,
                window=60,
                endpoint="/api/v1/users",
            )
