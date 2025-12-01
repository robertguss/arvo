"""Cache module for Redis-backed caching.

Provides:
- Redis client connection management
- OAuth state storage with TTL
"""

from app.core.cache.redis import get_redis, redis_client
from app.core.cache.oauth_state import (
    get_oauth_state,
    store_oauth_state,
    OAuthStateData,
)

__all__ = [
    "get_redis",
    "redis_client",
    "get_oauth_state",
    "store_oauth_state",
    "OAuthStateData",
]

