"""SQLAlchemy declarative base and common mixins."""

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import DateTime, ForeignKey, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Base class for all SQLAlchemy models."""

    pass


class UUIDMixin:
    """Mixin that adds a UUID primary key."""

    id: Mapped[UUID] = mapped_column(
        primary_key=True,
        default=uuid4,
        index=True,
    )


class TimestampMixin:
    """Mixin that adds created_at and updated_at timestamps."""

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class TenantMixin:
    """Mixin that adds tenant_id for multi-tenancy support.

    All tenant-scoped models should inherit from this mixin.
    The tenant_id foreign key references the tenants table.
    """

    tenant_id: Mapped[UUID] = mapped_column(
        ForeignKey("tenants.id", ondelete="CASCADE"),
        index=True,
        nullable=False,
    )


class AuditMixin:
    """Marker mixin to enable automatic audit logging.

    Models that inherit from this mixin will have their changes
    automatically captured in the audit log when they are created,
    updated, or deleted.

    The SQLAlchemy event listeners in app.core.audit.middleware
    check for the __audit__ attribute to determine if a model
    should be audited.

    Example:
        class Project(Base, UUIDMixin, TimestampMixin, TenantMixin, AuditMixin):
            __tablename__ = "projects"
            name: Mapped[str] = mapped_column(String(255))
    """

    # Marker attribute checked by audit middleware
    __audit__: bool = True
