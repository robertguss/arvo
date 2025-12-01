"""OAuth state storage with Redis backend.

Provides secure storage for OAuth CSRF state parameters with:
- Automatic TTL expiration
- One-time use (state is deleted after retrieval)
- Thread-safe for horizontal scaling
"""

from typing import TypedDict

import structlog

from app.core.cache.redis import RedisCache
from app.core.constants import OAUTH_STATE_TTL_SECONDS


logger = structlog.get_logger()


class OAuthStateData(TypedDict):
    """OAuth state data structure."""

    provider: str
    redirect_uri: str


# Redis cache instance for OAuth states
_oauth_cache = RedisCache(prefix="oauth:state:")


async def store_oauth_state(state: str, data: OAuthStateData) -> None:
    """Store OAuth state in Redis with TTL.

    The state is automatically expired after OAUTH_STATE_TTL_SECONDS
    to prevent stale state accumulation.

    Args:
        state: The random state string for CSRF protection
        data: State metadata (provider, redirect_uri)
    """
    await _oauth_cache.set_json(state, dict(data), OAUTH_STATE_TTL_SECONDS)

    logger.debug(
        "oauth_state_stored",
        state=state[:8] + "...",
        provider=data["provider"],
        ttl_seconds=OAUTH_STATE_TTL_SECONDS,
    )


async def get_oauth_state(state: str) -> OAuthStateData | None:
    """Retrieve and delete OAuth state (one-time use).

    The state is deleted after retrieval to prevent replay attacks.
    If the state has expired or doesn't exist, returns None.

    Args:
        state: The state string to retrieve

    Returns:
        OAuthStateData if found and valid, None otherwise
    """
    data = await _oauth_cache.get_json_and_delete(state)

    if data is None:
        logger.warning(
            "oauth_state_not_found",
            state=state[:8] + "...",
        )
        return None

    logger.debug(
        "oauth_state_retrieved",
        state=state[:8] + "...",
        provider=data.get("provider"),
    )

    # Validate required fields
    if "provider" not in data or "redirect_uri" not in data:
        logger.warning(
            "oauth_state_invalid",
            state=state[:8] + "...",
            data=data,
        )
        return None

    return OAuthStateData(
        provider=data["provider"],
        redirect_uri=data["redirect_uri"],
    )


async def verify_oauth_state(state: str, expected_provider: str) -> OAuthStateData | None:
    """Verify OAuth state and check provider matches.

    Combines state retrieval with provider verification.

    Args:
        state: The state string to verify
        expected_provider: The provider that should match

    Returns:
        OAuthStateData if valid and provider matches, None otherwise
    """
    data = await get_oauth_state(state)

    if data is None:
        return None

    if data["provider"] != expected_provider:
        logger.warning(
            "oauth_state_provider_mismatch",
            state=state[:8] + "...",
            expected=expected_provider,
            actual=data["provider"],
        )
        return None

    return data

