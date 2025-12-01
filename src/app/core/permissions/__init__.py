"""Permission system for role-based access control (RBAC)."""

from app.core.permissions.checker import PermissionChecker, check_permission
from app.core.permissions.decorators import require_permission
from app.core.permissions.models import Permission, Role, UserRole


__all__ = [
    # Models
    "Permission",
    # Checker
    "PermissionChecker",
    "Role",
    "UserRole",
    "check_permission",
    # Decorators
    "require_permission",
]
