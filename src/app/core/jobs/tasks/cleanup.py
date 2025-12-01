"""Cleanup tasks for expired data.

Background jobs that clean up expired tokens and other
temporary data from the database.
"""

from datetime import UTC, datetime
from typing import Any

import structlog
from sqlalchemy import delete

from app.modules.users.models import RefreshToken, RevokedToken


log = structlog.get_logger()


async def cleanup_expired_tokens(ctx: dict[str, Any]) -> dict[str, int]:
    """Clean up expired refresh tokens and revoked tokens.

    This job should be scheduled to run periodically (e.g., daily at 3 AM)
    to remove expired tokens from the database and keep tables small.

    Args:
        ctx: Worker context containing database session factory

    Returns:
        Dict with count of deleted tokens by type
    """
    session_factory = ctx["db_session_factory"]
    now = datetime.now(UTC)

    async with session_factory() as session:
        # Delete expired refresh tokens
        refresh_result = await session.execute(
            delete(RefreshToken).where(RefreshToken.expires_at < now)
        )
        refresh_count = refresh_result.rowcount

        # Delete expired revoked tokens (no longer needed after expiry)
        revoked_result = await session.execute(
            delete(RevokedToken).where(RevokedToken.expires_at < now)
        )
        revoked_count = revoked_result.rowcount

        await session.commit()

    log.info(
        "cleanup_expired_tokens_complete",
        refresh_tokens_deleted=refresh_count,
        revoked_tokens_deleted=revoked_count,
    )

    return {
        "refresh_tokens_deleted": refresh_count,
        "revoked_tokens_deleted": revoked_count,
    }

