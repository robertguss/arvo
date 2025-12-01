"""Permission decorators for route protection.

This module provides decorators that can be applied to FastAPI
routes to require specific permissions.
"""

from collections.abc import Callable
from functools import wraps
from typing import TYPE_CHECKING, ParamSpec, TypeVar

from app.core.errors import ForbiddenError
from app.core.permissions.checker import PermissionChecker


if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

    from app.modules.users.models import User


P = ParamSpec("P")
R = TypeVar("R")


def require_permission(resource: str, action: str) -> Callable[[Callable[P, R]], Callable[P, R]]:
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

    def decorator(func: Callable[P, R]) -> Callable[P, R]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            # Extract user and session from kwargs
            # These should be injected by FastAPI's dependency system
            user: User | None = kwargs.get("current_user")
            db: AsyncSession | None = kwargs.get("db")

            if not user:
                raise ForbiddenError(
                    "Authentication required",
                    error_code="auth_required",
                )

            # Superusers bypass permission checks
            if user.is_superuser:
                return await func(*args, **kwargs)

            if not db:
                raise ForbiddenError(
                    "Permission check failed",
                    error_code="permission_check_failed",
                )

            # Check permission
            checker = PermissionChecker(db)
            has_perm = await checker.has_permission(
                user.id,
                user.tenant_id,
                resource,
                action,
            )

            if not has_perm:
                raise ForbiddenError(
                    f"Missing required permission: {resource}:{action}",
                    error_code="permission_denied",
                    details={
                        "required_permission": f"{resource}:{action}",
                    },
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator


def require_any_permission(
    permissions: list[tuple[str, str]],
) -> Callable[[Callable[P, R]], Callable[P, R]]:
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

    def decorator(func: Callable[P, R]) -> Callable[P, R]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            user: User | None = kwargs.get("current_user")
            db: AsyncSession | None = kwargs.get("db")

            if not user:
                raise ForbiddenError(
                    "Authentication required",
                    error_code="auth_required",
                )

            if user.is_superuser:
                return await func(*args, **kwargs)

            if not db:
                raise ForbiddenError(
                    "Permission check failed",
                    error_code="permission_check_failed",
                )

            checker = PermissionChecker(db)
            has_any = await checker.has_any_permission(
                user.id,
                user.tenant_id,
                permissions,
            )

            if not has_any:
                perm_strs = [f"{r}:{a}" for r, a in permissions]
                raise ForbiddenError(
                    f"Missing required permission. Need one of: {', '.join(perm_strs)}",
                    error_code="permission_denied",
                    details={
                        "required_permissions": perm_strs,
                    },
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator


def require_all_permissions(
    permissions: list[tuple[str, str]],
) -> Callable[[Callable[P, R]], Callable[P, R]]:
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

    def decorator(func: Callable[P, R]) -> Callable[P, R]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            user: User | None = kwargs.get("current_user")
            db: AsyncSession | None = kwargs.get("db")

            if not user:
                raise ForbiddenError(
                    "Authentication required",
                    error_code="auth_required",
                )

            if user.is_superuser:
                return await func(*args, **kwargs)

            if not db:
                raise ForbiddenError(
                    "Permission check failed",
                    error_code="permission_check_failed",
                )

            checker = PermissionChecker(db)
            has_all = await checker.has_all_permissions(
                user.id,
                user.tenant_id,
                permissions,
            )

            if not has_all:
                perm_strs = [f"{r}:{a}" for r, a in permissions]
                raise ForbiddenError(
                    f"Missing required permissions: {', '.join(perm_strs)}",
                    error_code="permission_denied",
                    details={
                        "required_permissions": perm_strs,
                    },
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator

