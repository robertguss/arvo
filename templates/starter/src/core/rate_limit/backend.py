"""Redis sliding window rate limiter implementation.

Uses Redis sorted sets (ZSET) for accurate sliding window rate limiting.
More accurate than fixed windows and prevents burst abuse at window boundaries.
"""

import time
from dataclasses import dataclass

from app.core.cache.redis import redis_client


@dataclass
class RateLimitResult:
    """Result of a rate limit check."""

    allowed: bool
    limit: int
    remaining: int
    reset_time: int
    retry_after: int | None = None


class SlidingWindowRateLimiter:
    """Redis-based sliding window rate limiter.

    Uses sorted sets to track requests within a sliding time window.
    Each request is stored with its timestamp as the score, allowing
    efficient cleanup of old entries and accurate counting.
    """

    def __init__(self, prefix: str = "ratelimit") -> None:
        """Initialize the rate limiter.

        Args:
            prefix: Key prefix for Redis keys
        """
        self.prefix = prefix

    def _build_key(self, identifier: str, endpoint: str | None = None) -> str:
        """Build a Redis key for the rate limit.

        Args:
            identifier: User ID or IP address
            endpoint: Optional endpoint path for per-route limits

        Returns:
            Redis key string
        """
        if endpoint:
            # Normalize endpoint path
            endpoint_key = endpoint.replace("/", "_").strip("_")
            return f"{self.prefix}:{identifier}:{endpoint_key}"
        return f"{self.prefix}:{identifier}"

    async def is_allowed(
        self,
        identifier: str,
        limit: int,
        window: int,
        endpoint: str | None = None,
    ) -> RateLimitResult:
        """Check if a request is allowed under the rate limit.

        Uses a sliding window algorithm:
        1. Remove entries older than (now - window)
        2. Add current request timestamp
        3. Count entries in the window
        4. Allow if count <= limit

        Args:
            identifier: User ID or IP address to rate limit
            limit: Maximum number of requests allowed in the window
            window: Time window in seconds
            endpoint: Optional endpoint for per-route limits

        Returns:
            RateLimitResult with allowed status and metadata
        """
        key = self._build_key(identifier, endpoint)
        now = time.time()
        window_start = now - window

        async with redis_client() as client, client.pipeline(transaction=True) as pipe:
            # Remove entries outside the window
            pipe.zremrangebyscore(key, 0, window_start)
            # Add current request with timestamp as score
            pipe.zadd(key, {str(now): now})
            # Count requests in window
            pipe.zcard(key)
            # Set key expiry to window duration
            pipe.expire(key, window)

            results = await pipe.execute()
            count = results[2]

        remaining = max(0, limit - count)
        reset_time = int(now + window)
        allowed = count <= limit

        return RateLimitResult(
            allowed=allowed,
            limit=limit,
            remaining=remaining,
            reset_time=reset_time,
            retry_after=window if not allowed else None,
        )

    async def reset(self, identifier: str, endpoint: str | None = None) -> bool:
        """Reset rate limit for an identifier.

        Args:
            identifier: User ID or IP address
            endpoint: Optional endpoint path

        Returns:
            True if key was deleted
        """
        key = self._build_key(identifier, endpoint)
        async with redis_client() as client:
            result = await client.delete(key)
            return result > 0

    async def get_current_count(
        self,
        identifier: str,
        window: int,
        endpoint: str | None = None,
    ) -> int:
        """Get current request count for an identifier.

        Args:
            identifier: User ID or IP address
            window: Time window in seconds
            endpoint: Optional endpoint path

        Returns:
            Number of requests in the current window
        """
        key = self._build_key(identifier, endpoint)
        now = time.time()
        window_start = now - window

        async with redis_client() as client:
            # Clean old entries and count
            await client.zremrangebyscore(key, 0, window_start)
            count = await client.zcard(key)
            return count


# Global rate limiter instance
rate_limiter = SlidingWindowRateLimiter()
