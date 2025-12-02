"""Caching decorators for functions and methods.

Provides @cached and @invalidate decorators for transparent
caching of function results using Redis.
"""

import hashlib
from collections.abc import Awaitable, Callable
from functools import wraps
from typing import Any, ParamSpec, TypeVar

from app.core.cache.redis import redis_client
from app.core.cache.serializers import deserialize, serialize


P = ParamSpec("P")
T = TypeVar("T")


def cached(
    ttl: int = 60,
    key_builder: Callable[..., str] | None = None,
    namespace: str = "cache",
) -> Callable[[Callable[P, Awaitable[T]]], Callable[P, Awaitable[T]]]:
    """Decorator to cache async function results.

    Args:
        ttl: Time-to-live in seconds (default: 60)
        key_builder: Custom function to build cache key from args
        namespace: Key namespace prefix (default: "cache")

    Returns:
        Decorated function with caching

    Example:
        @cached(ttl=300, key_builder=lambda user_id: f"user:{user_id}")
        async def get_user(user_id: UUID) -> User:
            return await repo.get(user_id)

        # With default key generation
        @cached(ttl=60)
        async def get_settings() -> dict:
            return await load_settings()
    """

    def decorator(func: Callable[P, Awaitable[T]]) -> Callable[P, Awaitable[T]]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> T:
            # Build cache key
            if key_builder:
                custom_key = key_builder(*args, **kwargs)
                key = f"{namespace}:{custom_key}"
            else:
                # Generate key from function name and arguments
                key = _generate_key(namespace, func.__name__, args, kwargs)

            # Check cache
            async with redis_client() as client:
                cached_value = await client.get(key)

            if cached_value is not None:
                result: T = deserialize(cached_value)
                return result

            # Execute function and cache result
            result = await func(*args, **kwargs)

            async with redis_client() as client:
                await client.setex(key, ttl, serialize(result))

            return result

        return wrapper

    return decorator


def invalidate(
    pattern: str | None = None,
    key_builder: Callable[..., str] | None = None,
    namespace: str = "cache",
) -> Callable[[Callable[P, Awaitable[T]]], Callable[P, Awaitable[T]]]:
    """Decorator to invalidate cache after function execution.

    Args:
        pattern: Redis key pattern to invalidate (e.g., "user:*")
        key_builder: Function to build specific key to invalidate
        namespace: Key namespace prefix (default: "cache")

    Returns:
        Decorated function with cache invalidation

    Example:
        @invalidate(pattern="user:*")
        async def update_user(user_id: UUID, data: UserUpdate) -> User:
            return await repo.update(user_id, data)

        @invalidate(key_builder=lambda user_id, **_: f"user:{user_id}")
        async def delete_user(user_id: UUID) -> None:
            await repo.delete(user_id)
    """

    def decorator(func: Callable[P, Awaitable[T]]) -> Callable[P, Awaitable[T]]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> T:
            # Execute function first
            result = await func(*args, **kwargs)

            # Then invalidate cache
            async with redis_client() as client:
                if key_builder:
                    # Invalidate specific key
                    key = f"{namespace}:{key_builder(*args, **kwargs)}"
                    await client.delete(key)
                elif pattern:
                    # Invalidate by pattern
                    full_pattern = f"{namespace}:{pattern}"
                    cursor = 0
                    while True:
                        cursor, keys = await client.scan(
                            cursor=cursor,
                            match=full_pattern,
                            count=100,
                        )
                        if keys:
                            await client.delete(*keys)
                        if cursor == 0:
                            break

            return result

        return wrapper

    return decorator


def _generate_key(
    namespace: str, func_name: str, args: tuple[Any, ...], kwargs: dict[str, Any]
) -> str:
    """Generate a cache key from function arguments.

    Args:
        namespace: Key namespace
        func_name: Function name
        args: Positional arguments
        kwargs: Keyword arguments

    Returns:
        Unique cache key
    """
    # Create a stable hash of the arguments
    # Skip 'self' if present (first arg of methods)
    filtered_args = args
    if args and hasattr(args[0], "__class__"):
        # Check if first arg looks like 'self' (has class attributes)
        first_arg = args[0]
        if hasattr(first_arg, "__dict__") and not isinstance(
            first_arg, str | int | float | bool | list | dict | tuple
        ):
            filtered_args = args[1:]

    # Build argument string for hashing
    arg_parts = []
    for arg in filtered_args:
        arg_parts.append(_arg_to_string(arg))
    for k, v in sorted(kwargs.items()):
        arg_parts.append(f"{k}={_arg_to_string(v)}")

    arg_string = ":".join(arg_parts) if arg_parts else "noargs"

    # Hash if too long
    if len(arg_string) > 100:
        arg_hash = hashlib.md5(arg_string.encode()).hexdigest()[:16]
        return f"{namespace}:{func_name}:{arg_hash}"

    return f"{namespace}:{func_name}:{arg_string}"


def _arg_to_string(arg: Any) -> str:
    """Convert an argument to a string for cache key.

    Args:
        arg: Argument value

    Returns:
        String representation
    """
    if arg is None:
        return "none"
    if isinstance(arg, str | int | float | bool):
        return str(arg)
    if hasattr(arg, "hex"):  # UUID
        return str(arg.hex)
    if isinstance(arg, list | tuple):
        return f"[{','.join(_arg_to_string(x) for x in arg)}]"
    if isinstance(arg, dict):
        pairs = [f"{k}:{_arg_to_string(v)}" for k, v in sorted(arg.items())]
        return "{" + ",".join(pairs) + "}"
    # Fallback to repr hash
    return hashlib.md5(repr(arg).encode()).hexdigest()[:8]
