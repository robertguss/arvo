"""User database models."""

from datetime import datetime
from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database.base import Base, TenantMixin, TimestampMixin, UUIDMixin


if TYPE_CHECKING:
    from app.core.permissions.models import Role
    from app.modules.tenants.models import Tenant


class User(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """User model representing an authenticated user.

    Users belong to a tenant and can authenticate via email/password
    or OAuth providers.

    Attributes:
        email: Unique email address within the tenant
        password_hash: Bcrypt-hashed password (nullable for OAuth users)
        full_name: User's full name
        is_active: Whether the user can log in
        is_superuser: Whether the user has admin privileges
        oauth_provider: OAuth provider name (google, microsoft, github)
        oauth_id: User's ID from the OAuth provider
    """

    __tablename__ = "users"

    __table_args__ = (
        # Composite index for tenant-scoped email uniqueness
        Index("ix_users_tenant_email", "tenant_id", "email", unique=True),
        # Index for OAuth lookups
        Index("ix_users_oauth", "oauth_provider", "oauth_id"),
    )

    email: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
        index=True,
    )
    password_hash: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    full_name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean,
        default=True,
        nullable=False,
    )
    is_superuser: Mapped[bool] = mapped_column(
        Boolean,
        default=False,
        nullable=False,
    )

    # OAuth fields
    oauth_provider: Mapped[str | None] = mapped_column(
        String(50),
        nullable=True,
    )
    oauth_id: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )

    # Relationships - use lazy="raise" to prevent N+1 queries
    # Load these explicitly with selectinload() when needed
    tenant: Mapped["Tenant"] = relationship(
        "Tenant",
        lazy="raise",
    )
    roles: Mapped[list["Role"]] = relationship(
        "Role",
        secondary="user_roles",
        back_populates="users",
        lazy="raise",
    )

    def __repr__(self) -> str:
        return f"<User(id={self.id}, email={self.email}, tenant_id={self.tenant_id})>"


class RefreshToken(Base, UUIDMixin, TimestampMixin):
    """Refresh token for JWT authentication.

    Stores refresh tokens with their expiration and revocation status.
    Tokens are associated with a specific user.

    Attributes:
        user_id: The user this token belongs to
        token_hash: SHA-256 hash of the refresh token
        expires_at: When the token expires
        revoked: Whether the token has been revoked
        user_agent: The client user agent that created the token
        ip_address: The IP address that created the token
    """

    __tablename__ = "refresh_tokens"

    user_id: Mapped[UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    token_hash: Mapped[str] = mapped_column(
        String(64),  # SHA-256 hash length
        nullable=False,
        unique=True,
        index=True,
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        index=True,
    )
    revoked: Mapped[bool] = mapped_column(
        Boolean,
        default=False,
        nullable=False,
    )
    user_agent: Mapped[str | None] = mapped_column(
        String(512),
        nullable=True,
    )
    ip_address: Mapped[str | None] = mapped_column(
        String(45),  # IPv6 max length
        nullable=True,
    )

    # Relationship - use lazy="raise" to prevent N+1 queries
    user: Mapped["User"] = relationship(
        "User",
        lazy="raise",
    )

    def __repr__(self) -> str:
        return f"<RefreshToken(id={self.id}, user_id={self.user_id}, revoked={self.revoked})>"


class RevokedToken(Base, UUIDMixin, TimestampMixin):
    """Revoked JWT access tokens.

    Stores JTIs (JWT IDs) of revoked access tokens for blacklist checking.
    Tokens are automatically cleaned up after expiration.

    Attributes:
        jti: Unique JWT ID
        expires_at: When the original token would have expired
    """

    __tablename__ = "revoked_tokens"

    jti: Mapped[str] = mapped_column(
        String(64),  # Token ID length
        nullable=False,
        unique=True,
        index=True,
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        index=True,
    )

    def __repr__(self) -> str:
        return f"<RevokedToken(id={self.id}, jti={self.jti[:8]}...)>"
