"""Integration tests for Redis cache."""

import pytest

from app.core.cache.redis import (
    RedisCache,
    RedisPoolHolder,
    _get_pool,
    redis_client,
)


@pytest.fixture(autouse=True)
async def reset_redis_pool():
    """Reset Redis pool before each test to avoid event loop issues."""
    # Clear the pool reference to get fresh connections in each test's event loop
    # Don't try to disconnect as it may fail if the event loop is different
    RedisPoolHolder.pool = None
    yield
    # Clean up test keys
    try:
        async with redis_client() as client:
            keys = await client.keys("test:*")
            if keys:
                await client.delete(*keys)
    except Exception:
        pass  # Ignore cleanup errors
    finally:
        # Clear pool reference after test
        RedisPoolHolder.pool = None


@pytest.fixture
def cache():
    """Provide a RedisCache instance with test prefix."""
    return RedisCache(prefix="test:")


class TestRedisPoolManagement:
    """Tests for Redis connection pool management."""

    @pytest.mark.asyncio
    async def test_get_pool_creates_pool(self):
        """Verify pool is created on first access."""
        pool = _get_pool()
        assert pool is not None
        assert RedisPoolHolder.pool is pool

    @pytest.mark.asyncio
    async def test_get_pool_returns_existing_pool(self):
        """Verify same pool is returned on subsequent calls."""
        pool1 = _get_pool()
        pool2 = _get_pool()
        assert pool1 is pool2


class TestRedisClientContextManager:
    """Tests for redis_client context manager."""

    @pytest.mark.asyncio
    async def test_redis_client_basic_operations(self):
        """Verify basic Redis operations via context manager."""
        async with redis_client() as client:
            await client.set("test:key1", "value1")
            result = await client.get("test:key1")

        assert result == "value1"


class TestRedisCacheKey:
    """Tests for RedisCache key generation."""

    def test_key_with_prefix(self):
        """Verify key is prefixed correctly."""
        cache = RedisCache(prefix="myapp:")
        assert cache._key("user:123") == "myapp:user:123"

    def test_key_without_prefix(self):
        """Verify key is returned as-is without prefix."""
        cache = RedisCache()
        assert cache._key("user:123") == "user:123"

    def test_key_with_empty_prefix(self):
        """Verify empty prefix is handled correctly."""
        cache = RedisCache(prefix="")
        assert cache._key("user:123") == "user:123"


class TestRedisCacheGet:
    """Tests for RedisCache.get method."""

    @pytest.mark.asyncio
    async def test_get_existing_key(self, cache: RedisCache):
        """Verify existing key value is returned."""
        await cache.set("mykey", "myvalue")
        result = await cache.get("mykey")

        assert result == "myvalue"

    @pytest.mark.asyncio
    async def test_get_nonexistent_key(self, cache: RedisCache):
        """Verify None is returned for missing key."""
        result = await cache.get("nonexistent_key_12345")

        assert result is None


class TestRedisCacheSet:
    """Tests for RedisCache.set method."""

    @pytest.mark.asyncio
    async def test_set_without_ttl(self, cache: RedisCache):
        """Verify value is set without expiration."""
        await cache.set("permanent", "value")

        result = await cache.get("permanent")
        assert result == "value"

    @pytest.mark.asyncio
    async def test_set_with_ttl(self, cache: RedisCache):
        """Verify value is set with TTL."""
        await cache.set("temporary", "value", ttl_seconds=300)

        result = await cache.get("temporary")
        assert result == "value"

        # Verify TTL was set
        async with redis_client() as client:
            ttl = await client.ttl("test:temporary")
            assert ttl > 0 and ttl <= 300


class TestRedisCacheDelete:
    """Tests for RedisCache.delete method."""

    @pytest.mark.asyncio
    async def test_delete_existing_key(self, cache: RedisCache):
        """Verify existing key is deleted and returns True."""
        await cache.set("todelete", "value")
        result = await cache.delete("todelete")

        assert result is True
        assert await cache.get("todelete") is None

    @pytest.mark.asyncio
    async def test_delete_nonexistent_key(self, cache: RedisCache):
        """Verify deleting nonexistent key returns False."""
        result = await cache.delete("nonexistent_key_67890")

        assert result is False


class TestRedisCacheExists:
    """Tests for RedisCache.exists method."""

    @pytest.mark.asyncio
    async def test_exists_existing_key(self, cache: RedisCache):
        """Verify True is returned for existing key."""
        await cache.set("exists", "value")
        result = await cache.exists("exists")

        assert result is True

    @pytest.mark.asyncio
    async def test_exists_nonexistent_key(self, cache: RedisCache):
        """Verify False is returned for missing key."""
        result = await cache.exists("nonexistent_key_abcde")

        assert result is False


class TestRedisCacheGetAndDelete:
    """Tests for RedisCache.get_and_delete method."""

    @pytest.mark.asyncio
    async def test_get_and_delete_existing_key(self, cache: RedisCache):
        """Verify value is returned and key is deleted."""
        await cache.set("oneshot", "secret")
        result = await cache.get_and_delete("oneshot")

        assert result == "secret"
        assert await cache.get("oneshot") is None

    @pytest.mark.asyncio
    async def test_get_and_delete_nonexistent_key(self, cache: RedisCache):
        """Verify None is returned for missing key."""
        result = await cache.get_and_delete("nonexistent_key_xyz")

        assert result is None


class TestRedisCacheJson:
    """Tests for RedisCache JSON methods."""

    @pytest.mark.asyncio
    async def test_set_json(self, cache: RedisCache):
        """Verify JSON data is stored correctly."""
        data = {"name": "Test", "count": 42, "active": True}

        await cache.set_json("json_key", data)

        result = await cache.get_json("json_key")
        assert result == data

    @pytest.mark.asyncio
    async def test_set_json_with_ttl(self, cache: RedisCache):
        """Verify JSON data is stored with TTL."""
        data = {"temp": "data"}

        await cache.set_json("json_temp", data, ttl_seconds=300)

        result = await cache.get_json("json_temp")
        assert result == data

        # Verify TTL was set
        async with redis_client() as client:
            ttl = await client.ttl("test:json_temp")
            assert ttl > 0 and ttl <= 300

    @pytest.mark.asyncio
    async def test_get_json_existing_key(self, cache: RedisCache):
        """Verify JSON data is retrieved correctly."""
        data = {"items": [1, 2, 3], "nested": {"key": "value"}}

        await cache.set_json("complex", data)
        result = await cache.get_json("complex")

        assert result == data

    @pytest.mark.asyncio
    async def test_get_json_nonexistent_key(self, cache: RedisCache):
        """Verify None is returned for missing key."""
        result = await cache.get_json("nonexistent_json_key")

        assert result is None

    @pytest.mark.asyncio
    async def test_get_json_and_delete(self, cache: RedisCache):
        """Verify JSON is returned and key is deleted."""
        data = {"token": "abc123"}

        await cache.set_json("oneshot_json", data)
        result = await cache.get_json_and_delete("oneshot_json")

        assert result == data
        assert await cache.get_json("oneshot_json") is None

    @pytest.mark.asyncio
    async def test_get_json_and_delete_nonexistent(self, cache: RedisCache):
        """Verify None is returned for missing key."""
        result = await cache.get_json_and_delete("nonexistent_json_xyz")

        assert result is None
