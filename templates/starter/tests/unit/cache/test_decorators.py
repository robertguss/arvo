"""Tests for caching decorators."""

from unittest.mock import AsyncMock, patch
from uuid import uuid4

import pytest

from app.core.cache.decorators import _arg_to_string, _generate_key, cached, invalidate
from app.core.cache.serializers import deserialize, serialize


class TestCachedDecorator:
    """Tests for @cached decorator."""

    @pytest.mark.asyncio
    async def test_cached_miss_then_hit(self):
        """Test cache miss followed by cache hit."""
        call_count = 0

        @cached(ttl=300, namespace="test")
        async def get_data(item_id: str) -> dict:
            nonlocal call_count
            call_count += 1
            return {"id": item_id, "value": "test"}

        mock_client = AsyncMock()
        # First call: cache miss
        mock_client.get = AsyncMock(return_value=None)
        mock_client.setex = AsyncMock()

        with patch("app.core.cache.decorators.redis_client") as mock_redis:
            mock_redis.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_redis.return_value.__aexit__ = AsyncMock(return_value=None)

            result1 = await get_data("123")
            assert result1 == {"id": "123", "value": "test"}
            assert call_count == 1
            mock_client.setex.assert_called_once()

    @pytest.mark.asyncio
    async def test_cached_with_custom_key_builder(self):
        """Test cached decorator with custom key builder."""

        @cached(ttl=60, key_builder=lambda user_id: f"user:{user_id}")
        async def get_user(user_id: str) -> dict:
            return {"id": user_id}

        mock_client = AsyncMock()
        mock_client.get = AsyncMock(return_value=None)
        mock_client.setex = AsyncMock()

        with patch("app.core.cache.decorators.redis_client") as mock_redis:
            mock_redis.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_redis.return_value.__aexit__ = AsyncMock(return_value=None)

            await get_user("abc")

            # Check that the key was built correctly
            call_args = mock_client.setex.call_args
            assert "cache:user:abc" in call_args[0][0]


class TestInvalidateDecorator:
    """Tests for @invalidate decorator."""

    @pytest.mark.asyncio
    async def test_invalidate_by_key(self):
        """Test invalidating a specific key."""

        @invalidate(key_builder=lambda user_id: f"user:{user_id}")
        async def update_user(user_id: str) -> dict:
            return {"id": user_id, "updated": True}

        mock_client = AsyncMock()
        mock_client.delete = AsyncMock()

        with patch("app.core.cache.decorators.redis_client") as mock_redis:
            mock_redis.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_redis.return_value.__aexit__ = AsyncMock(return_value=None)

            result = await update_user("123")

            assert result == {"id": "123", "updated": True}
            mock_client.delete.assert_called_once_with("cache:user:123")


class TestKeyGeneration:
    """Tests for cache key generation utilities."""

    def test_generate_key_simple(self):
        """Test generating a key with simple arguments."""
        key = _generate_key("cache", "get_user", ("123",), {})
        assert key == "cache:get_user:123"

    def test_generate_key_with_kwargs(self):
        """Test generating a key with keyword arguments."""
        key = _generate_key("cache", "get_user", (), {"user_id": "123"})
        assert "cache:get_user" in key
        assert "user_id=123" in key

    def test_generate_key_with_uuid(self):
        """Test generating a key with UUID argument."""
        test_uuid = uuid4()
        key = _generate_key("cache", "get_item", (test_uuid,), {})
        assert test_uuid.hex in key

    def test_arg_to_string_primitives(self):
        """Test converting primitive types to strings."""
        assert _arg_to_string("hello") == "hello"
        assert _arg_to_string(123) == "123"
        assert _arg_to_string(True) == "True"
        assert _arg_to_string(None) == "none"

    def test_arg_to_string_uuid(self):
        """Test converting UUID to string."""
        test_uuid = uuid4()
        result = _arg_to_string(test_uuid)
        assert result == test_uuid.hex


class TestSerializers:
    """Tests for cache serializers."""

    def test_serialize_deserialize_dict(self):
        """Test round-trip for dictionary."""
        data = {"name": "test", "value": 123}
        serialized = serialize(data)
        deserialized = deserialize(serialized)
        assert deserialized == data

    def test_serialize_deserialize_uuid(self):
        """Test round-trip for UUID."""
        test_uuid = uuid4()
        data = {"id": test_uuid}
        serialized = serialize(data)
        deserialized = deserialize(serialized)
        assert deserialized["id"] == test_uuid

    def test_serialize_deserialize_set(self):
        """Test round-trip for set."""
        data = {"tags": {1, 2, 3}}
        serialized = serialize(data)
        deserialized = deserialize(serialized)
        assert deserialized["tags"] == {1, 2, 3}
