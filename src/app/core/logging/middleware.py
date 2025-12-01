"""Request logging middleware.

This module provides middleware for logging all HTTP requests and responses
with structured logging via structlog.
"""

import time
from typing import Any

import structlog
from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint


logger = structlog.get_logger()


class RequestLoggingMiddleware(BaseHTTPMiddleware):
    """Middleware that logs all HTTP requests and responses.

    Logs include:
    - Request method, path, and query parameters
    - Response status code
    - Request duration
    - Request ID (if set by RequestIdMiddleware)
    - User ID and tenant ID (if authenticated)

    Sensitive headers and paths can be excluded from logging.
    """

    def __init__(
        self,
        app: Any,
        exclude_paths: list[str] | None = None,
        log_request_body: bool = False,
        log_response_body: bool = False,
    ) -> None:
        """Initialize the middleware.

        Args:
            app: The ASGI application
            exclude_paths: Paths to exclude from logging (e.g., health checks)
            log_request_body: Whether to log request bodies (use with caution)
            log_response_body: Whether to log response bodies (use with caution)
        """
        super().__init__(app)
        self.exclude_paths = exclude_paths or [
            "/health/live",
            "/health/ready",
            "/docs",
            "/redoc",
            "/openapi.json",
        ]
        self.log_request_body = log_request_body
        self.log_response_body = log_response_body

    async def dispatch(
        self,
        request: Request,
        call_next: RequestResponseEndpoint,
    ) -> Response:
        """Process the request and log details.

        Args:
            request: The incoming request
            call_next: The next middleware/handler

        Returns:
            The response from the handler
        """
        # Skip excluded paths
        if any(request.url.path.startswith(path) for path in self.exclude_paths):
            return await call_next(request)

        # Record start time
        start_time = time.perf_counter()

        # Extract request details
        request_id = getattr(request.state, "request_id", None)
        method = request.method
        path = request.url.path
        query = str(request.url.query) if request.url.query else None
        client_host = request.client.host if request.client else None

        # Log request start
        log_data: dict[str, Any] = {
            "method": method,
            "path": path,
            "client_ip": client_host,
        }

        if query:
            log_data["query"] = query

        if request_id:
            log_data["request_id"] = request_id

        logger.info("request_started", **log_data)

        # Process request
        try:
            response = await call_next(request)
        except Exception as exc:
            # Log exception
            duration_ms = (time.perf_counter() - start_time) * 1000
            logger.exception(
                "request_failed",
                method=method,
                path=path,
                duration_ms=round(duration_ms, 2),
                error=str(exc),
            )
            raise

        # Calculate duration
        duration_ms = (time.perf_counter() - start_time) * 1000

        # Log request completion
        completion_data: dict[str, Any] = {
            "method": method,
            "path": path,
            "status_code": response.status_code,
            "duration_ms": round(duration_ms, 2),
        }

        if request_id:
            completion_data["request_id"] = request_id

        # Add user context if available
        user_id = getattr(request.state, "user_id", None)
        tenant_id = getattr(request.state, "tenant_id", None)

        if user_id:
            completion_data["user_id"] = str(user_id)
        if tenant_id:
            completion_data["tenant_id"] = str(tenant_id)

        # Choose log level based on status code
        if response.status_code >= 500:
            logger.error("request_completed", **completion_data)
        elif response.status_code >= 400:
            logger.warning("request_completed", **completion_data)
        else:
            logger.info("request_completed", **completion_data)

        return response


def get_client_ip(request: Request) -> str | None:
    """Extract the real client IP from a request.

    Handles X-Forwarded-For header for proxied requests.

    Args:
        request: The incoming request

    Returns:
        The client IP address or None
    """
    # Check X-Forwarded-For header first (for proxied requests)
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        # X-Forwarded-For can contain multiple IPs; the first is the original client
        return forwarded.split(",")[0].strip()

    # Check X-Real-IP header (some proxies use this)
    real_ip = request.headers.get("X-Real-IP")
    if real_ip:
        return real_ip

    # Fall back to direct client
    if request.client:
        return request.client.host

    return None

