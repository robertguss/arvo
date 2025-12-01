"""Rate limiting middleware for global request limits.

Applies rate limits to all requests based on user ID (authenticated)
or IP address (unauthenticated).
"""

from typing import ClassVar

from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from app.config import settings
from app.core.rate_limit.backend import rate_limiter


class RateLimitMiddleware(BaseHTTPMiddleware):
    """Middleware that applies global rate limits to all requests.

    Uses user ID for authenticated requests, IP address for unauthenticated.
    Adds standard rate limit headers to all responses.
    """

    # Paths to exclude from rate limiting
    EXCLUDED_PATHS: ClassVar[set[str]] = {
        "/health/live",
        "/health/ready",
        "/docs",
        "/redoc",
        "/openapi.json",
    }

    async def dispatch(
        self, request: Request, call_next: RequestResponseEndpoint
    ) -> Response:
        """Process request and apply rate limiting.

        Args:
            request: Incoming HTTP request
            call_next: Next middleware/handler in chain

        Returns:
            Response with rate limit headers
        """
        # Skip rate limiting for excluded paths
        if request.url.path in self.EXCLUDED_PATHS:
            return await call_next(request)

        # Determine identifier: user_id if authenticated, else IP
        identifier = self._get_identifier(request)

        # Check rate limit
        result = await rate_limiter.is_allowed(
            identifier=identifier,
            limit=settings.rate_limit_requests,
            window=settings.rate_limit_window,
        )

        # If rate limited, return 429
        if not result.allowed:
            return JSONResponse(
                status_code=429,
                content={
                    "type": f"{settings.api_docs_base_url}/errors/rate-limit",
                    "title": "Too Many Requests",
                    "status": 429,
                    "detail": "Rate limit exceeded. Please slow down.",
                },
                headers={
                    "X-RateLimit-Limit": str(result.limit),
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": str(result.reset_time),
                    "Retry-After": str(result.retry_after),
                },
            )

        # Process request
        response = await call_next(request)

        # Add rate limit headers to successful responses
        response.headers["X-RateLimit-Limit"] = str(result.limit)
        response.headers["X-RateLimit-Remaining"] = str(result.remaining)
        response.headers["X-RateLimit-Reset"] = str(result.reset_time)

        return response

    def _get_identifier(self, request: Request) -> str:
        """Extract rate limit identifier from request.

        Uses user_id from request state if authenticated,
        otherwise falls back to client IP address.

        Args:
            request: HTTP request

        Returns:
            Identifier string (user:{id} or ip:{address})
        """
        # Check for authenticated user in request state
        user_id = getattr(request.state, "user_id", None)
        if user_id:
            return f"user:{user_id}"

        # Fall back to IP address
        # Check X-Forwarded-For for proxied requests
        forwarded_for = request.headers.get("X-Forwarded-For")
        if forwarded_for:
            # Take the first IP in the chain (original client)
            client_ip = forwarded_for.split(",")[0].strip()
        else:
            client_ip = request.client.host if request.client else "unknown"

        return f"ip:{client_ip}"
