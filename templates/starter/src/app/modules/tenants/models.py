"""Tenant database models."""

from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database.base import Base, TimestampMixin, UUIDMixin


class Tenant(Base, UUIDMixin, TimestampMixin):
    """Tenant model representing an organization/workspace.

    All tenant-scoped data references this table via tenant_id.
    """

    __tablename__ = "tenants"

    name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
        index=True,
    )
    slug: Mapped[str] = mapped_column(
        String(63),
        nullable=False,
        unique=True,
        index=True,
    )
    is_active: Mapped[bool] = mapped_column(
        default=True,
        nullable=False,
    )

    def __repr__(self) -> str:
        return f"<Tenant(id={self.id}, name={self.name}, slug={self.slug})>"
