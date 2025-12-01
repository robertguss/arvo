"""Rate limiting decorator for per-route configuration.

Allows setting custom rate limits on individual endpoints that
override the global middleware limits.
"""

from collections.abc import Awaitable, Callable
from functools import wraps
from typing import ParamSpec, TypeVar

from fastapi import Request
from starlette.responses import JSONResponse, Response

from app.config import settings
from app.core.rate_limit.backend import rate_limiter


P = ParamSpec("P")
T = TypeVar("T")


def rate_limit(
    requests: int | None = None,
    window: int | None = None,
    key_func: Callable[[Request], str] | None = None,
) -> Callable[
    [Callable[P, Awaitable[T]]], Callable[P, Awaitable[T | Response]]
]:
    """Decorator to apply custom rate limits to a route.

    Args:
        requests: Maximum requests allowed in window (default: from settings)
        window: Time window in seconds (default: from settings)
        key_func: Custom function to extract identifier from request

    Returns:
        Decorated function with rate limiting

    Example:
        @router.post("/ai/generate")
        @rate_limit(requests=10, window=60)  # 10 per minute
        async def generate(request: Request):
            ...
    """
    limit = requests or settings.rate_limit_requests
    window_seconds = window or settings.rate_limit_window

    def decorator(
        func: Callable[P, Awaitable[T]],
    ) -> Callable[P, Awaitable[T | Response]]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> T | Response:
            # Find Request in args or kwargs
            request: Request | None = None
            for arg in args:
                if isinstance(arg, Request):
                    request = arg
                    break
            if request is None:
                req_from_kwargs = kwargs.get("request")
                if isinstance(req_from_kwargs, Request):
                    request = req_from_kwargs

            if request is None:
                # No request found, skip rate limiting
                return await func(*args, **kwargs)

            # Get identifier
            if key_func:
                identifier = key_func(request)
            else:
                identifier = _get_default_identifier(request)

            # Check rate limit for this specific endpoint
            result = await rate_limiter.is_allowed(
                identifier=identifier,
                limit=limit,
                window=window_seconds,
                endpoint=request.url.path,
            )

            if not result.allowed:
                return JSONResponse(
                    status_code=429,
                    content={
                        "type": f"{settings.api_docs_base_url}/errors/rate-limit",
                        "title": "Too Many Requests",
                        "status": 429,
                        "detail": f"Rate limit exceeded for this endpoint. "
                        f"Limit: {limit} requests per {window_seconds} seconds.",
                    },
                    headers={
                        "X-RateLimit-Limit": str(result.limit),
                        "X-RateLimit-Remaining": "0",
                        "X-RateLimit-Reset": str(result.reset_time),
                        "Retry-After": str(result.retry_after),
                    },
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator


def _get_default_identifier(request: Request) -> str:
    """Get default rate limit identifier from request.

    Args:
        request: HTTP request

    Returns:
        Identifier string
    """
    # Check for authenticated user
    user_id = getattr(request.state, "user_id", None)
    if user_id:
        return f"user:{user_id}"

    # Fall back to IP
    forwarded_for = request.headers.get("X-Forwarded-For")
    if forwarded_for:
        client_ip = forwarded_for.split(",")[0].strip()
    else:
        client_ip = request.client.host if request.client else "unknown"

    return f"ip:{client_ip}"

