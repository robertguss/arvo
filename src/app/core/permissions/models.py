"""Permission system database models.

This module defines the RBAC (Role-Based Access Control) models:
- Role: A named set of permissions within a tenant
- Permission: An action that can be performed on a resource
- UserRole: Junction table linking users to roles
"""

from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import Column, ForeignKey, String, Table, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database.base import Base, TenantMixin, TimestampMixin, UUIDMixin


if TYPE_CHECKING:
    from app.modules.users.models import User


# Junction table for Role <-> Permission many-to-many relationship
role_permissions = Table(
    "role_permissions",
    Base.metadata,
    Column(
        "role_id", Uuid, ForeignKey("roles.id", ondelete="CASCADE"), primary_key=True
    ),
    Column(
        "permission_id",
        Uuid,
        ForeignKey("permissions.id", ondelete="CASCADE"),
        primary_key=True,
    ),
)


class Permission(Base, UUIDMixin, TimestampMixin):
    """Permission model representing an action on a resource.

    Permissions are global (not tenant-scoped) and define what actions
    can be performed on what resources.

    Attributes:
        resource: The resource being protected (e.g., "users", "projects")
        action: The action being performed (e.g., "read", "write", "delete")
        description: Human-readable description of the permission

    Examples:
        - resource="users", action="read" -> Can view users
        - resource="users", action="delete" -> Can delete users
        - resource="billing", action="manage" -> Can manage billing
    """

    __tablename__ = "permissions"
    __table_args__ = (
        UniqueConstraint("resource", "action", name="uq_permission_resource_action"),
    )

    resource: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
        index=True,
    )
    action: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
    )
    description: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )

    # Relationships
    roles: Mapped[list["Role"]] = relationship(
        "Role",
        secondary=role_permissions,
        back_populates="permissions",
    )

    @property
    def name(self) -> str:
        """Return the permission name as 'resource:action'."""
        return f"{self.resource}:{self.action}"

    def __repr__(self) -> str:
        return f"<Permission({self.resource}:{self.action})>"


class Role(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """Role model representing a named set of permissions.

    Roles are tenant-scoped, allowing each tenant to define their own
    role structure with custom permissions.

    Attributes:
        name: Role name (e.g., "admin", "member", "viewer")
        description: Human-readable description of the role
        is_default: Whether this role is assigned to new users by default

    Common roles:
        - admin: Full access to all resources
        - member: Standard access for team members
        - viewer: Read-only access
    """

    __tablename__ = "roles"
    __table_args__ = (
        UniqueConstraint("tenant_id", "name", name="uq_role_tenant_name"),
    )

    name: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
        index=True,
    )
    description: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    is_default: Mapped[bool] = mapped_column(
        default=False,
        nullable=False,
    )

    # Relationships
    permissions: Mapped[list["Permission"]] = relationship(
        "Permission",
        secondary=role_permissions,
        back_populates="roles",
        lazy="selectin",
    )
    users: Mapped[list["User"]] = relationship(
        "User",
        secondary="user_roles",
        back_populates="roles",
    )

    def has_permission(self, resource: str, action: str) -> bool:
        """Check if this role has a specific permission.

        Args:
            resource: The resource to check
            action: The action to check

        Returns:
            True if the role has the permission
        """
        for permission in self.permissions:
            if permission.resource == resource and permission.action == action:
                return True
            # Check for wildcard permissions
            if permission.resource == resource and permission.action == "*":
                return True
            if permission.resource == "*" and permission.action == action:
                return True
            if permission.resource == "*" and permission.action == "*":
                return True
        return False

    def __repr__(self) -> str:
        return f"<Role(id={self.id}, name={self.name}, tenant_id={self.tenant_id})>"


class UserRole(Base, TimestampMixin):
    """Junction table linking users to roles.

    A user can have multiple roles within a tenant, and their effective
    permissions are the union of all their roles' permissions.
    """

    __tablename__ = "user_roles"
    __table_args__ = (UniqueConstraint("user_id", "role_id", name="uq_user_role"),)

    user_id: Mapped[UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
        index=True,
    )
    role_id: Mapped[UUID] = mapped_column(
        ForeignKey("roles.id", ondelete="CASCADE"),
        primary_key=True,
        index=True,
    )

    def __repr__(self) -> str:
        return f"<UserRole(user_id={self.user_id}, role_id={self.role_id})>"
