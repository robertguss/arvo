"""Permission checking logic.

This module provides functions for checking if a user has
specific permissions based on their assigned roles.
"""

from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.permissions.models import Role, UserRole


if TYPE_CHECKING:
    from app.modules.users.models import User


class PermissionChecker:
    """Service for checking user permissions.

    Evaluates whether a user has specific permissions based on
    their assigned roles within their tenant.
    """

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_user_roles(self, user_id: UUID, tenant_id: UUID) -> list[Role]:
        """Get all roles assigned to a user.

        Args:
            user_id: The user's UUID
            tenant_id: The tenant's UUID

        Returns:
            List of roles assigned to the user
        """
        stmt = (
            select(Role)
            .join(UserRole, UserRole.role_id == Role.id)
            .where(
                UserRole.user_id == user_id,
                Role.tenant_id == tenant_id,
            )
            .options(selectinload(Role.permissions))
        )
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def has_permission(
        self,
        user_id: UUID,
        tenant_id: UUID,
        resource: str,
        action: str,
    ) -> bool:
        """Check if a user has a specific permission.

        Args:
            user_id: The user's UUID
            tenant_id: The tenant's UUID
            resource: The resource to check (e.g., "users")
            action: The action to check (e.g., "read", "write", "delete")

        Returns:
            True if the user has the permission, False otherwise
        """
        roles = await self.get_user_roles(user_id, tenant_id)

        return any(role.has_permission(resource, action) for role in roles)

    async def has_any_permission(
        self,
        user_id: UUID,
        tenant_id: UUID,
        permissions: list[tuple[str, str]],
    ) -> bool:
        """Check if a user has any of the specified permissions.

        Args:
            user_id: The user's UUID
            tenant_id: The tenant's UUID
            permissions: List of (resource, action) tuples to check

        Returns:
            True if the user has at least one permission
        """
        roles = await self.get_user_roles(user_id, tenant_id)

        for resource, action in permissions:
            for role in roles:
                if role.has_permission(resource, action):
                    return True

        return False

    async def has_all_permissions(
        self,
        user_id: UUID,
        tenant_id: UUID,
        permissions: list[tuple[str, str]],
    ) -> bool:
        """Check if a user has all of the specified permissions.

        Args:
            user_id: The user's UUID
            tenant_id: The tenant's UUID
            permissions: List of (resource, action) tuples to check

        Returns:
            True if the user has all permissions
        """
        roles = await self.get_user_roles(user_id, tenant_id)

        for resource, action in permissions:
            has_perm = False
            for role in roles:
                if role.has_permission(resource, action):
                    has_perm = True
                    break
            if not has_perm:
                return False

        return True

    async def get_user_permissions(
        self,
        user_id: UUID,
        tenant_id: UUID,
    ) -> set[str]:
        """Get all permissions for a user.

        Args:
            user_id: The user's UUID
            tenant_id: The tenant's UUID

        Returns:
            Set of permission strings in "resource:action" format
        """
        roles = await self.get_user_roles(user_id, tenant_id)
        permissions: set[str] = set()

        for role in roles:
            for permission in role.permissions:
                permissions.add(permission.name)

        return permissions


async def check_permission(
    user: "User",
    resource: str,
    action: str,
    session: AsyncSession,
) -> bool:
    """Convenience function to check a user's permission.

    For use in route handlers when you need a simple permission check.

    Args:
        user: The user to check
        resource: The resource to check
        action: The action to check
        session: Database session

    Returns:
        True if user has permission

    Note:
        Superusers always return True.
    """
    # Superusers have all permissions
    if user.is_superuser:
        return True

    checker = PermissionChecker(session)
    return await checker.has_permission(user.id, user.tenant_id, resource, action)

