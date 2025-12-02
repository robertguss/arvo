"""Domain exceptions for the application.

These exceptions represent business-logic errors and are automatically
converted to RFC 7807 Problem Details responses by the exception handlers.
"""

from typing import Any


class AppException(Exception):
    """Base exception for all application errors.

    All domain exceptions should inherit from this class.

    Attributes:
        message: Human-readable error message
        error_code: Machine-readable error code for clients
        status_code: HTTP status code for the response
        details: Additional error details
    """

    message: str = "An unexpected error occurred"
    error_code: str = "internal_error"
    status_code: int = 500

    def __init__(
        self,
        message: str | None = None,
        error_code: str | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        self.message = message or self.message
        self.error_code = error_code or self.error_code
        self.details = details or {}
        super().__init__(self.message)


class NotFoundError(AppException):
    """Raised when a requested resource is not found.

    Example:
        raise NotFoundError("User not found", details={"user_id": str(user_id)})
    """

    message = "Resource not found"
    error_code = "not_found"
    status_code = 404

    def __init__(
        self,
        message: str | None = None,
        resource: str | None = None,
        resource_id: str | None = None,
        **kwargs: Any,
    ) -> None:
        details = kwargs.pop("details", {})
        if resource:
            details["resource"] = resource
        if resource_id:
            details["resource_id"] = resource_id
        super().__init__(message=message, details=details, **kwargs)


class ConflictError(AppException):
    """Raised when there's a conflict with existing data.

    Example:
        raise ConflictError("Email already registered", details={"email": email})
    """

    message = "Resource conflict"
    error_code = "conflict"
    status_code = 409


class ValidationError(AppException):
    """Raised when request data fails validation.

    Example:
        raise ValidationError(
            "Invalid input data",
            errors=[{"field": "email", "message": "Invalid email format"}]
        )
    """

    message = "Validation error"
    error_code = "validation_error"
    status_code = 422

    def __init__(
        self,
        message: str | None = None,
        errors: list[dict[str, Any]] | None = None,
        **kwargs: Any,
    ) -> None:
        details = kwargs.pop("details", {})
        if errors:
            details["errors"] = errors
        super().__init__(message=message, details=details, **kwargs)


class UnauthorizedError(AppException):
    """Raised when authentication is required but not provided or invalid.

    Example:
        raise UnauthorizedError("Invalid access token")
    """

    message = "Authentication required"
    error_code = "unauthorized"
    status_code = 401


class ForbiddenError(AppException):
    """Raised when user lacks permission to access a resource.

    Example:
        raise ForbiddenError(
            "Insufficient permissions",
            details={"required_permission": "users:delete"}
        )
    """

    message = "Access forbidden"
    error_code = "forbidden"
    status_code = 403


class BadRequestError(AppException):
    """Raised for general client errors.

    Example:
        raise BadRequestError("Invalid request format")
    """

    message = "Bad request"
    error_code = "bad_request"
    status_code = 400


class RateLimitError(AppException):
    """Raised when rate limit is exceeded.

    Example:
        raise RateLimitError(
            "Too many requests",
            details={"retry_after": 60}
        )
    """

    message = "Rate limit exceeded"
    error_code = "rate_limit_exceeded"
    status_code = 429


class ServiceUnavailableError(AppException):
    """Raised when a required service is unavailable.

    Example:
        raise ServiceUnavailableError("Database connection failed")
    """

    message = "Service temporarily unavailable"
    error_code = "service_unavailable"
    status_code = 503
