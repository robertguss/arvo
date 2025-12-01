"""Redis client configuration and connection management.

Provides async Redis client with connection pooling for
caching, session storage, and distributed state.
"""

import json
from contextlib import asynccontextmanager
from typing import TYPE_CHECKING, Any

import redis.asyncio as redis
from redis.asyncio.connection import ConnectionPool

from app.config import settings


if TYPE_CHECKING:
    from collections.abc import AsyncGenerator


class RedisPoolHolder:
    """Holder for the Redis connection pool.

    Uses a class attribute to manage module-level state without
    global statements.
    """

    pool: "ConnectionPool[Any]| None" = None


def _get_pool() -> "ConnectionPool[Any]":
    """Get or create the Redis connection pool."""
    if RedisPoolHolder.pool is None:
        RedisPoolHolder.pool = ConnectionPool.from_url(
            str(settings.redis_url),
            max_connections=50,
            decode_responses=True,
        )
    return RedisPoolHolder.pool


async def get_redis() -> "AsyncGenerator[redis.Redis[Any], None]":
    """Get a Redis client from the connection pool.

    Yields:
        Redis client instance

    Usage:
        async for client in get_redis():
            await client.set("key", "value")
    """
    client = redis.Redis(connection_pool=_get_pool())
    try:
        yield client
    finally:
        await client.close()


@asynccontextmanager
async def redis_client() -> "AsyncGenerator[redis.Redis[Any], None]":
    """Context manager for Redis client.

    Usage:
        async with redis_client() as client:
            await client.set("key", "value")
    """
    client = redis.Redis(connection_pool=_get_pool())
    try:
        yield client
    finally:
        await client.close()


async def close_redis_pool() -> None:
    """Close the Redis connection pool.

    Call this during application shutdown.
    """
    if RedisPoolHolder.pool is not None:
        await RedisPoolHolder.pool.disconnect()
        RedisPoolHolder.pool = None


class RedisCache:
    """High-level Redis cache interface.

    Provides typed methods for common caching operations.
    """

    def __init__(self, prefix: str = "") -> None:
        """Initialize cache with optional key prefix.

        Args:
            prefix: Prefix for all keys (e.g., "myapp:")
        """
        self.prefix = prefix

    def _key(self, key: str) -> str:
        """Generate prefixed key."""
        return f"{self.prefix}{key}" if self.prefix else key

    async def get(self, key: str) -> str | None:
        """Get a value from cache.

        Args:
            key: Cache key

        Returns:
            Cached value or None if not found
        """
        async with redis_client() as client:
            return await client.get(self._key(key))

    async def set(
        self,
        key: str,
        value: str,
        ttl_seconds: int | None = None,
    ) -> None:
        """Set a value in cache.

        Args:
            key: Cache key
            value: Value to cache
            ttl_seconds: Optional TTL in seconds
        """
        async with redis_client() as client:
            if ttl_seconds:
                await client.setex(self._key(key), ttl_seconds, value)
            else:
                await client.set(self._key(key), value)

    async def delete(self, key: str) -> bool:
        """Delete a key from cache.

        Args:
            key: Cache key

        Returns:
            True if key was deleted, False if it didn't exist
        """
        async with redis_client() as client:
            result = await client.delete(self._key(key))
            return result > 0

    async def exists(self, key: str) -> bool:
        """Check if a key exists in cache.

        Args:
            key: Cache key

        Returns:
            True if key exists
        """
        async with redis_client() as client:
            return await client.exists(self._key(key)) > 0

    async def get_and_delete(self, key: str) -> str | None:
        """Get a value and delete it atomically (one-time use).

        Args:
            key: Cache key

        Returns:
            Cached value or None if not found
        """
        async with redis_client() as client:
            return await client.getdel(self._key(key))

    async def set_json(
        self,
        key: str,
        value: dict[str, Any],
        ttl_seconds: int | None = None,
    ) -> None:
        """Set a JSON value in cache.

        Args:
            key: Cache key
            value: Dictionary to cache as JSON
            ttl_seconds: Optional TTL in seconds
        """
        await self.set(key, json.dumps(value), ttl_seconds)

    async def get_json(self, key: str) -> dict[str, Any] | None:
        """Get a JSON value from cache.

        Args:
            key: Cache key

        Returns:
            Parsed dictionary or None if not found
        """
        data = await self.get(key)
        if data:
            result: dict[str, Any] = json.loads(data)
            return result
        return None

    async def get_json_and_delete(self, key: str) -> dict[str, Any] | None:
        """Get a JSON value and delete it atomically.

        Args:
            key: Cache key

        Returns:
            Parsed dictionary or None if not found
        """
        data = await self.get_and_delete(key)
        if data:
            result: dict[str, Any] = json.loads(data)
            return result
        return None
