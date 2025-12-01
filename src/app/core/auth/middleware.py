"""Authentication and tenant context middleware.

This module provides middleware for:
- Injecting tenant context into requests
- Request tracing with unique IDs
"""

import uuid
from typing import TYPE_CHECKING

import structlog
from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint

from app.core.auth.backend import decode_token


if TYPE_CHECKING:
    from starlette.types import ASGIApp


logger = structlog.get_logger()


class TenantContextMiddleware(BaseHTTPMiddleware):
    """Middleware that injects tenant context into requests.

    Extracts tenant_id from the JWT token (if present) and adds it
    to request.state for use by downstream handlers.

    Attributes:
        exclude_paths: Paths that don't require tenant context
    """

    def __init__(
        self,
        app: "ASGIApp",
        exclude_paths: list[str] | None = None,
    ) -> None:
        super().__init__(app)
        self.exclude_paths = exclude_paths or [
            "/health",
            "/docs",
            "/redoc",
            "/openapi.json",
            "/api/v1/auth/login",
            "/api/v1/auth/register",
            "/api/v1/auth/refresh",
            "/api/v1/auth/oauth",
        ]

    async def dispatch(
        self,
        request: Request,
        call_next: RequestResponseEndpoint,
    ) -> Response:
        """Process the request and inject tenant context.

        Args:
            request: The incoming request
            call_next: The next middleware/handler

        Returns:
            The response from the handler
        """
        # Skip for excluded paths
        if any(request.url.path.startswith(path) for path in self.exclude_paths):
            return await call_next(request)

        # Try to extract token from Authorization header
        auth_header = request.headers.get("Authorization")
        if auth_header and auth_header.startswith("Bearer "):
            token = auth_header.split(" ", 1)[1]
            token_data = decode_token(token)

            if token_data:
                request.state.tenant_id = token_data.tenant_id
                request.state.user_id = token_data.user_id

                # Bind to structlog context
                structlog.contextvars.bind_contextvars(
                    tenant_id=str(token_data.tenant_id),
                    user_id=str(token_data.user_id),
                )

        return await call_next(request)


class RequestIdMiddleware(BaseHTTPMiddleware):
    """Middleware that adds a unique request ID to each request.

    The request ID is added to:
    - request.state.request_id
    - Response header X-Request-ID
    - Structlog context
    """

    async def dispatch(
        self,
        request: Request,
        call_next: RequestResponseEndpoint,
    ) -> Response:
        """Process the request and add request ID.

        Args:
            request: The incoming request
            call_next: The next middleware/handler

        Returns:
            The response with X-Request-ID header
        """
        # Get request ID from header or generate new one
        request_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())

        # Add to request state
        request.state.request_id = request_id
        request.state.trace_id = request_id  # Alias for error handler

        # Bind to structlog context
        structlog.contextvars.bind_contextvars(request_id=request_id)

        # Process request
        response = await call_next(request)

        # Add to response header
        response.headers["X-Request-ID"] = request_id

        # Clear structlog context
        structlog.contextvars.unbind_contextvars("request_id", "tenant_id", "user_id")

        return response

