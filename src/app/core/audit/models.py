"""Audit log database model.

Stores audit entries for tracking who did what, when.
Supports both automatic change tracking and manual entries.
"""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database.base import Base, UUIDMixin


class AuditLog(Base, UUIDMixin):
    """Audit log entry for tracking changes and actions.

    Attributes:
        tenant_id: The tenant this action belongs to
        user_id: The user who performed the action (nullable for system actions)
        action: Type of action (create, update, delete, login, export, etc.)
        resource_type: Type of resource affected (user, project, settings, etc.)
        resource_id: ID of the affected resource (nullable for general actions)
        ip_address: Client IP address
        user_agent: Client user agent string
        request_id: Correlation ID for request tracing
        changes: Dictionary of field changes {field: {old: x, new: y}}
        metadata: Additional context about the action
        created_at: When the action occurred
    """

    __tablename__ = "audit_logs"

    tenant_id: Mapped[UUID] = mapped_column(
        ForeignKey("tenants.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )

    # What happened
    action: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        index=True,
    )
    resource_type: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
        index=True,
    )
    resource_id: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
        index=True,
    )

    # Request context
    ip_address: Mapped[str | None] = mapped_column(
        String(45),  # IPv6 max length
        nullable=True,
    )
    user_agent: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    request_id: Mapped[str | None] = mapped_column(
        String(64),
        nullable=True,
        index=True,
    )

    # Data
    changes: Mapped[dict[str, Any] | None] = mapped_column(
        JSONB,
        nullable=True,
    )
    metadata_: Mapped[dict[str, Any] | None] = mapped_column(
        "metadata",  # Column name in database
        JSONB,
        nullable=True,
    )

    # Timestamp
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
        index=True,
    )

    def __repr__(self) -> str:
        return (
            f"<AuditLog(id={self.id}, action={self.action}, "
            f"resource_type={self.resource_type}, resource_id={self.resource_id})>"
        )

