"""Tests for rate limiting backend."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.core.rate_limit.backend import RateLimitResult, SlidingWindowRateLimiter


class TestSlidingWindowRateLimiter:
    """Tests for SlidingWindowRateLimiter class."""

    def test_build_key_basic(self):
        """Test basic key building without endpoint."""
        limiter = SlidingWindowRateLimiter(prefix="ratelimit")
        key = limiter._build_key("user:123")
        assert key == "ratelimit:user:123"

    def test_build_key_with_endpoint(self):
        """Test key building with endpoint."""
        limiter = SlidingWindowRateLimiter(prefix="ratelimit")
        key = limiter._build_key("user:123", "/api/v1/users")
        assert key == "ratelimit:user:123:api_v1_users"

    def test_build_key_custom_prefix(self):
        """Test key building with custom prefix."""
        limiter = SlidingWindowRateLimiter(prefix="custom")
        key = limiter._build_key("ip:192.168.1.1")
        assert key == "custom:ip:192.168.1.1"

    @pytest.mark.asyncio
    async def test_is_allowed_under_limit(self):
        """Test that requests under limit are allowed."""
        limiter = SlidingWindowRateLimiter()

        # Mock Redis pipeline - pipeline commands don't return coroutines
        mock_pipeline = MagicMock()
        mock_pipeline.zremrangebyscore = MagicMock()
        mock_pipeline.zadd = MagicMock()
        mock_pipeline.zcard = MagicMock()
        mock_pipeline.expire = MagicMock()
        mock_pipeline.execute = AsyncMock(return_value=[0, True, 1, True])
        mock_pipeline.__aenter__ = AsyncMock(return_value=mock_pipeline)
        mock_pipeline.__aexit__ = AsyncMock(return_value=None)

        mock_client = MagicMock()
        mock_client.pipeline = MagicMock(return_value=mock_pipeline)

        with patch("app.core.rate_limit.backend.redis_client") as mock_redis:
            mock_redis.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_redis.return_value.__aexit__ = AsyncMock(return_value=None)

            result = await limiter.is_allowed(
                identifier="user:123",
                limit=100,
                window=60,
            )

            assert result.allowed is True
            assert result.limit == 100
            assert result.remaining == 99
            assert result.retry_after is None

    @pytest.mark.asyncio
    async def test_is_allowed_over_limit(self):
        """Test that requests over limit are denied."""
        limiter = SlidingWindowRateLimiter()

        # Mock Redis pipeline - pipeline commands don't return coroutines
        mock_pipeline = MagicMock()
        mock_pipeline.zremrangebyscore = MagicMock()
        mock_pipeline.zadd = MagicMock()
        mock_pipeline.zcard = MagicMock()
        mock_pipeline.expire = MagicMock()
        mock_pipeline.execute = AsyncMock(return_value=[0, True, 101, True])
        mock_pipeline.__aenter__ = AsyncMock(return_value=mock_pipeline)
        mock_pipeline.__aexit__ = AsyncMock(return_value=None)

        mock_client = MagicMock()
        mock_client.pipeline = MagicMock(return_value=mock_pipeline)

        with patch("app.core.rate_limit.backend.redis_client") as mock_redis:
            mock_redis.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_redis.return_value.__aexit__ = AsyncMock(return_value=None)

            result = await limiter.is_allowed(
                identifier="user:123",
                limit=100,
                window=60,
            )

            assert result.allowed is False
            assert result.limit == 100
            assert result.remaining == 0
            assert result.retry_after == 60


class TestRateLimitResult:
    """Tests for RateLimitResult dataclass."""

    def test_allowed_result(self):
        """Test creating an allowed result."""
        result = RateLimitResult(
            allowed=True,
            limit=100,
            remaining=95,
            reset_time=1234567890,
        )
        assert result.allowed is True
        assert result.limit == 100
        assert result.remaining == 95
        assert result.retry_after is None

    def test_denied_result(self):
        """Test creating a denied result."""
        result = RateLimitResult(
            allowed=False,
            limit=100,
            remaining=0,
            reset_time=1234567890,
            retry_after=30,
        )
        assert result.allowed is False
        assert result.remaining == 0
        assert result.retry_after == 30

