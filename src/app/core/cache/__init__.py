"""Cache module for Redis-backed caching.

Provides:
- Redis client connection management
- OAuth state storage with TTL
- Caching decorators (@cached, @invalidate)
- Serialization utilities for cache values
"""

from app.core.cache.decorators import cached, invalidate
from app.core.cache.oauth_state import (
    OAuthStateData,
    get_oauth_state,
    store_oauth_state,
)
from app.core.cache.redis import RedisCache, get_redis, redis_client
from app.core.cache.serializers import deserialize, serialize


__all__ = [
    "OAuthStateData",
    "RedisCache",
    "cached",
    "deserialize",
    "get_oauth_state",
    "get_redis",
    "invalidate",
    "redis_client",
    "serialize",
    "store_oauth_state",
]

