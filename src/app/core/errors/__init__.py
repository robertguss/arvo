"""Error handling module with RFC 7807 Problem Details."""

from app.core.errors.exceptions import (
    AppException,
    BadRequestError,
    ConflictError,
    ForbiddenError,
    NotFoundError,
    RateLimitError,
    ServiceUnavailableError,
    UnauthorizedError,
    ValidationError,
)
from app.core.errors.handlers import (
    FieldError,
    ProblemDetail,
    register_exception_handlers,
)


__all__ = [
    # Exceptions
    "AppException",
    "BadRequestError",
    "ConflictError",
    # Handlers
    "FieldError",
    "ForbiddenError",
    "NotFoundError",
    "ProblemDetail",
    "RateLimitError",
    "ServiceUnavailableError",
    "UnauthorizedError",
    "ValidationError",
    "register_exception_handlers",
]

