"""Permission decorators for route protection.

This module provides decorators that can be applied to FastAPI
routes to require specific permissions.
"""

from collections.abc import Awaitable, Callable
from functools import wraps
from typing import TYPE_CHECKING, Any, ParamSpec, TypeVar, cast

import structlog

from app.core.errors import ForbiddenError
from app.core.permissions.checker import PermissionChecker


if TYPE_CHECKING:
    from fastapi import Request
    from sqlalchemy.ext.asyncio import AsyncSession

    from app.modules.users.models import User


logger = structlog.get_logger()

P = ParamSpec("P")
R = TypeVar("R")


async def _check_permissions(
    user: "User",
    db: "AsyncSession",
    permissions: list[tuple[str, str]],
    require_all: bool,
    request: "Request | None" = None,
) -> bool:
    """Common permission checking logic.

    Args:
        user: The user to check permissions for
        db: Database session
        permissions: List of (resource, action) tuples to check
        require_all: If True, user must have all permissions; if False, any one
        request: Optional request for logging context

    Returns:
        True if permission check passes

    Raises:
        ForbiddenError: If permission check fails
    """
    # Superusers bypass permission checks (with audit logging - P2-6)
    if user.is_superuser:
        logger.warning(
            "superuser_bypass",
            user_id=str(user.id),
            tenant_id=str(user.tenant_id),
            permissions=[f"{r}:{a}" for r, a in permissions],
            endpoint=request.url.path if request else "unknown",
        )
        return True

    checker = PermissionChecker(db)

    if require_all:
        has_perm = await checker.has_all_permissions(
            user.id,
            user.tenant_id,
            permissions,
        )
    elif len(permissions) == 1:
        resource, action = permissions[0]
        has_perm = await checker.has_permission(
            user.id,
            user.tenant_id,
            resource,
            action,
        )
    else:
        has_perm = await checker.has_any_permission(
            user.id,
            user.tenant_id,
            permissions,
        )

    return has_perm


def _get_user_and_db(
    kwargs: dict[str, Any],
) -> tuple["User | None", "AsyncSession | None", "Request | None"]:
    """Extract user, db session, and request from kwargs.

    Args:
        kwargs: Function keyword arguments

    Returns:
        Tuple of (user, db, request)
    """
    user = cast("User | None", kwargs.get("current_user"))
    db = cast("AsyncSession | None", kwargs.get("db"))
    request = cast("Request | None", kwargs.get("request"))
    return user, db, request


def require_permission(
    resource: str, action: str
) -> Callable[[Callable[P, Awaitable[R]]], Callable[P, Awaitable[R]]]:
    """Decorator that requires a specific permission to access a route.

    Usage:
        @router.delete("/users/{user_id}")
        @require_permission("users", "delete")
        async def delete_user(user_id: UUID, current_user: CurrentUser):
            ...

    Args:
        resource: The resource being accessed (e.g., "users")
        action: The action being performed (e.g., "delete")

    Returns:
        Decorator function

    Raises:
        ForbiddenError: If user lacks the required permission
    """
    return require_all_permissions([(resource, action)])


def require_any_permission(
    permissions: list[tuple[str, str]],
) -> Callable[[Callable[P, Awaitable[R]]], Callable[P, Awaitable[R]]]:
    """Decorator that requires any one of the specified permissions.

    Usage:
        @router.get("/reports")
        @require_any_permission([("reports", "read"), ("admin", "read")])
        async def get_reports(current_user: CurrentUser):
            ...

    Args:
        permissions: List of (resource, action) tuples

    Returns:
        Decorator function
    """

    def decorator(func: Callable[P, Awaitable[R]]) -> Callable[P, Awaitable[R]]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            user, db, request = _get_user_and_db(kwargs)

            if not user:
                raise ForbiddenError(
                    "Authentication required",
                    error_code="auth_required",
                )

            if not db:
                raise ForbiddenError(
                    "Permission check failed",
                    error_code="permission_check_failed",
                )

            has_perm = await _check_permissions(
                user, db, permissions, require_all=False, request=request
            )

            if not has_perm:
                perm_strs = [f"{r}:{a}" for r, a in permissions]
                raise ForbiddenError(
                    f"Missing required permission. Need one of: {', '.join(perm_strs)}",
                    error_code="permission_denied",
                    details={"required_permissions": perm_strs},
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator


def require_all_permissions(
    permissions: list[tuple[str, str]],
) -> Callable[[Callable[P, Awaitable[R]]], Callable[P, Awaitable[R]]]:
    """Decorator that requires all of the specified permissions.

    Usage:
        @router.post("/sensitive-operation")
        @require_all_permissions([("admin", "write"), ("audit", "write")])
        async def sensitive_operation(current_user: CurrentUser):
            ...

    Args:
        permissions: List of (resource, action) tuples

    Returns:
        Decorator function
    """

    def decorator(func: Callable[P, Awaitable[R]]) -> Callable[P, Awaitable[R]]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            user, db, request = _get_user_and_db(kwargs)

            if not user:
                raise ForbiddenError(
                    "Authentication required",
                    error_code="auth_required",
                )

            if not db:
                raise ForbiddenError(
                    "Permission check failed",
                    error_code="permission_check_failed",
                )

            has_perm = await _check_permissions(
                user, db, permissions, require_all=True, request=request
            )

            if not has_perm:
                perm_strs = [f"{r}:{a}" for r, a in permissions]
                raise ForbiddenError(
                    f"Missing required permissions: {', '.join(perm_strs)}",
                    error_code="permission_denied",
                    details={"required_permissions": perm_strs},
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator
