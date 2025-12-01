"""RFC 7807 Problem Details exception handlers.

This module provides standardized error responses following the
RFC 7807 "Problem Details for HTTP APIs" specification.

See: https://tools.ietf.org/html/rfc7807
"""

from typing import TYPE_CHECKING, Any, cast

import structlog
from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from app.config import settings
from app.core.errors.exceptions import AppException


if TYPE_CHECKING:
    from starlette.types import ExceptionHandler


logger = structlog.get_logger()


class FieldError(BaseModel):
    """Represents a single field validation error."""

    field: str
    message: str
    type: str | None = None


class ProblemDetail(BaseModel):
    """RFC 7807 Problem Details response schema.

    Attributes:
        type: URI reference identifying the problem type
        title: Short human-readable summary
        status: HTTP status code
        detail: Human-readable explanation specific to this occurrence
        instance: URI reference identifying this specific occurrence
        errors: List of field-level errors (for validation errors)
        trace_id: Request trace ID for debugging
    """

    type: str
    title: str
    status: int
    detail: str
    instance: str | None = None
    errors: list[FieldError] | None = None
    trace_id: str | None = None

    model_config = {"extra": "allow"}


def _get_trace_id(request: Request) -> str | None:
    """Extract trace ID from request state if available."""
    return getattr(request.state, "trace_id", None)


def _get_error_type_uri(error_code: str) -> str:
    """Generate a URI for the error type.

    In production, this should point to documentation about the error.
    """
    return f"{settings.api_docs_base_url}/errors/{error_code}"


async def app_exception_handler(request: Request, exc: AppException) -> JSONResponse:
    """Handle application-specific exceptions.

    Converts AppException subclasses to RFC 7807 Problem Details responses.
    """
    logger.warning(
        "app_exception",
        error_code=exc.error_code,
        message=exc.message,
        status_code=exc.status_code,
        path=str(request.url.path),
        details=exc.details,
    )

    content: dict[str, Any] = ProblemDetail(
        type=_get_error_type_uri(exc.error_code),
        title=exc.error_code.replace("_", " ").title(),
        status=exc.status_code,
        detail=exc.message,
        instance=str(request.url.path),
        trace_id=_get_trace_id(request),
    ).model_dump(exclude_none=True)

    # Add any additional details from the exception
    if exc.details:
        for key, value in exc.details.items():
            if key not in content:
                content[key] = value

    return JSONResponse(
        status_code=exc.status_code,
        content=content,
    )


async def validation_exception_handler(
    request: Request, exc: RequestValidationError
) -> JSONResponse:
    """Handle Pydantic validation errors.

    Converts FastAPI/Pydantic validation errors to RFC 7807 format
    with detailed field-level error information.
    """
    errors: list[FieldError] = []

    for error in exc.errors():
        # Build field path from location
        loc = error.get("loc", ())
        # Skip "body" prefix in field path
        field_parts = [str(part) for part in loc if part != "body"]
        field = ".".join(field_parts) if field_parts else "unknown"

        errors.append(
            FieldError(
                field=field,
                message=error.get("msg", "Invalid value"),
                type=error.get("type"),
            )
        )

    logger.warning(
        "validation_error",
        path=str(request.url.path),
        error_count=len(errors),
    )

    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content=ProblemDetail(
            type=_get_error_type_uri("validation_error"),
            title="Validation Error",
            status=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Request validation failed",
            instance=str(request.url.path),
            errors=errors,
            trace_id=_get_trace_id(request),
        ).model_dump(exclude_none=True),
    )


async def generic_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Handle unexpected exceptions.

    Catches all unhandled exceptions and returns a generic 500 error.
    The actual error details are logged but not exposed to clients.
    """
    logger.exception(
        "unhandled_exception",
        path=str(request.url.path),
        error_type=type(exc).__name__,
    )

    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content=ProblemDetail(
            type=_get_error_type_uri("internal_error"),
            title="Internal Server Error",
            status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="An unexpected error occurred",
            instance=str(request.url.path),
            trace_id=_get_trace_id(request),
        ).model_dump(exclude_none=True),
    )


def register_exception_handlers(app: FastAPI) -> None:
    """Register all exception handlers with the FastAPI app.

    Call this function during app initialization:

        app = FastAPI()
        register_exception_handlers(app)
    """
    app.add_exception_handler(
        AppException, cast("ExceptionHandler", app_exception_handler)
    )
    app.add_exception_handler(
        RequestValidationError, cast("ExceptionHandler", validation_exception_handler)
    )
    app.add_exception_handler(Exception, generic_exception_handler)

