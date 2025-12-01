"""User database models."""

from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import Boolean, ForeignKey, String, Text
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

    # Relationships
    tenant: Mapped["Tenant"] = relationship(
        "Tenant",
        lazy="selectin",
    )
    roles: Mapped[list["Role"]] = relationship(
        "Role",
        secondary="user_roles",
        back_populates="users",
        lazy="selectin",
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
    expires_at: Mapped[str] = mapped_column(
        nullable=False,
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

    # Relationship
    user: Mapped["User"] = relationship(
        "User",
        lazy="selectin",
    )

    def __repr__(self) -> str:
        return f"<RefreshToken(id={self.id}, user_id={self.user_id}, revoked={self.revoked})>"

