"""performance_and_security_fixes

Revision ID: b2c3d4e5f6g7
Revises: a1b2c3d4e5f6
Create Date: 2025-12-01 00:02:00.000000

This migration adds:
- Composite indexes for performance (P2-2)
- Changes expires_at from String to DateTime (P2-3)
- Adds revoked_tokens table for JWT revocation (P1-3)
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


# revision identifiers, used by Alembic.
revision: str = "b2c3d4e5f6g7"
down_revision: Union[str, None] = "a1b2c3d4e5f6"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade database schema."""
    # P2-2: Add composite indexes for users table
    op.create_index(
        "ix_users_tenant_email",
        "users",
        ["tenant_id", "email"],
        unique=True,
    )
    op.create_index(
        "ix_users_oauth",
        "users",
        ["oauth_provider", "oauth_id"],
        unique=False,
    )

    # P2-3: Change expires_at from String to DateTime
    # First, add a new column
    op.add_column(
        "refresh_tokens",
        sa.Column(
            "expires_at_new",
            sa.DateTime(timezone=True),
            nullable=True,
        ),
    )

    # Migrate data from string to datetime
    op.execute(
        """
        UPDATE refresh_tokens
        SET expires_at_new = expires_at::timestamptz
        WHERE expires_at IS NOT NULL
        """
    )

    # Drop old column and rename new one
    op.drop_column("refresh_tokens", "expires_at")
    op.alter_column(
        "refresh_tokens",
        "expires_at_new",
        new_column_name="expires_at",
        nullable=False,
    )

    # Add index on expires_at for efficient cleanup queries
    op.create_index(
        "ix_refresh_tokens_expires_at",
        "refresh_tokens",
        ["expires_at"],
    )

    # P1-3: Create revoked_tokens table for JWT revocation
    op.create_table(
        "revoked_tokens",
        sa.Column("jti", sa.String(length=64), nullable=False),
        sa.Column(
            "expires_at",
            sa.DateTime(timezone=True),
            nullable=False,
        ),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_revoked_tokens_id",
        "revoked_tokens",
        ["id"],
        unique=False,
    )
    op.create_index(
        "ix_revoked_tokens_jti",
        "revoked_tokens",
        ["jti"],
        unique=True,
    )
    op.create_index(
        "ix_revoked_tokens_expires_at",
        "revoked_tokens",
        ["expires_at"],
    )


def downgrade() -> None:
    """Downgrade database schema."""
    # Drop revoked_tokens table
    op.drop_index("ix_revoked_tokens_expires_at", table_name="revoked_tokens")
    op.drop_index("ix_revoked_tokens_jti", table_name="revoked_tokens")
    op.drop_index("ix_revoked_tokens_id", table_name="revoked_tokens")
    op.drop_table("revoked_tokens")

    # Revert expires_at back to String
    op.drop_index("ix_refresh_tokens_expires_at", table_name="refresh_tokens")

    op.add_column(
        "refresh_tokens",
        sa.Column(
            "expires_at_old",
            sa.String(),
            nullable=True,
        ),
    )

    op.execute(
        """
        UPDATE refresh_tokens
        SET expires_at_old = expires_at::text
        WHERE expires_at IS NOT NULL
        """
    )

    op.drop_column("refresh_tokens", "expires_at")
    op.alter_column(
        "refresh_tokens",
        "expires_at_old",
        new_column_name="expires_at",
        nullable=False,
    )

    # Drop composite indexes from users table
    op.drop_index("ix_users_oauth", table_name="users")
    op.drop_index("ix_users_tenant_email", table_name="users")

