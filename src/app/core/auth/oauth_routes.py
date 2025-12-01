"""OAuth2 API routes.

Provides endpoints for OAuth authentication flow:
- Initiate authorization
- Handle callback
- Link/unlink accounts
"""


import structlog
from fastapi import APIRouter, Query, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.dependencies import DBSession
from app.config import settings
from app.core.auth.backend import (
    create_access_token,
    create_refresh_token,
    get_token_expiration,
    hash_token,
)
from app.core.auth.oauth import (
    OAuthProvider,
    OAuthUserInfo,
    generate_state,
    get_available_providers,
    get_provider,
)
from app.core.cache.oauth_state import (
    OAuthStateData,
    store_oauth_state,
    verify_oauth_state,
)
from app.core.errors import BadRequestError, NotFoundError
from app.core.utils.text import generate_slug
from app.modules.tenants.models import Tenant
from app.modules.users.models import RefreshToken, User
from app.modules.users.repos import RefreshTokenRepository, UserRepository
from app.modules.users.schemas import TokenResponse


logger = structlog.get_logger()

router = APIRouter(prefix="/auth/oauth", tags=["oauth"])


class OAuthProvidersResponse(BaseModel):
    """List of available OAuth providers."""

    providers: list[str]


class OAuthAuthorizeResponse(BaseModel):
    """Response with authorization URL."""

    url: str
    state: str


# ============================================================
# Helper Functions for OAuth Callback (P1-8 refactor)
# ============================================================


async def _verify_state(state: str, provider: str) -> OAuthStateData:
    """Verify OAuth state parameter.

    Args:
        state: The state string from callback
        provider: Expected provider name

    Returns:
        Verified state data

    Raises:
        BadRequestError: If state is invalid or expired
    """
    state_data = await verify_oauth_state(state, provider)
    if not state_data:
        raise BadRequestError(
            "Invalid or expired OAuth state",
            error_code="invalid_state",
        )
    return state_data


def _get_oauth_provider(provider: str) -> OAuthProvider:
    """Get and validate OAuth provider.

    Args:
        provider: Provider name

    Returns:
        Configured OAuth provider

    Raises:
        NotFoundError: If provider not configured
    """
    oauth_provider = get_provider(provider)
    if not oauth_provider:
        raise NotFoundError(
            f"OAuth provider '{provider}' not configured",
            resource="oauth_provider",
            resource_id=provider,
        )
    return oauth_provider


async def _exchange_code_for_user_info(
    oauth_provider: OAuthProvider,
    code: str,
    redirect_uri: str,
    provider: str,
) -> OAuthUserInfo:
    """Exchange authorization code for user info.

    Args:
        oauth_provider: The OAuth provider instance
        code: Authorization code from callback
        redirect_uri: Redirect URI used in authorization
        provider: Provider name for logging

    Returns:
        User information from provider

    Raises:
        BadRequestError: If exchange fails
    """
    try:
        token_response = await oauth_provider.exchange_code(code, redirect_uri)

        access_token = token_response.get("access_token")
        if not access_token:
            raise BadRequestError(
                "No access token in OAuth response",
                error_code="missing_token",
            )

        return await oauth_provider.get_user_info(access_token)

    except BadRequestError:
        raise
    except Exception as e:
        logger.exception("oauth_code_exchange_failed", provider=provider)
        raise BadRequestError(
            f"OAuth authentication failed: {e!s}",
            error_code="oauth_failed",
        ) from None


async def _find_or_create_user(
    db: AsyncSession,
    user_info: OAuthUserInfo,
    provider: str,
) -> User:
    """Find existing user or create new one with tenant.

    Args:
        db: Database session
        user_info: User info from OAuth provider
        provider: OAuth provider name

    Returns:
        User (existing or newly created)
    """
    user_repo = UserRepository(db)

    # Try to find by OAuth ID (system-level: tenant not known during OAuth)
    user = await user_repo.get_by_oauth_system(provider, user_info.provider_id)

    if user:
        logger.debug(
            "oauth_found_existing_oauth_user",
            user_id=str(user.id),
            provider=provider,
        )
        return user

    # Try to find by email (system-level: could be existing user)
    user = await user_repo.get_by_email_system(user_info.email)

    if user:
        # Link OAuth to existing user
        user.oauth_provider = provider
        user.oauth_id = user_info.provider_id
        await db.flush()
        logger.info(
            "oauth_linked_existing_user",
            user_id=str(user.id),
            provider=provider,
        )
        return user

    # Create new tenant and user
    tenant = Tenant(
        name=f"{user_info.name}'s Workspace",
        slug=generate_slug(user_info.name),
    )
    db.add(tenant)
    await db.flush()

    user = User(
        email=user_info.email,
        full_name=user_info.name,
        oauth_provider=provider,
        oauth_id=user_info.provider_id,
        tenant_id=tenant.id,
        is_superuser=True,  # First user is superuser
    )
    user = await user_repo.create(user)

    logger.info(
        "oauth_created_new_user",
        user_id=str(user.id),
        tenant_id=str(tenant.id),
        provider=provider,
    )

    return user


async def _issue_tokens(
    db: AsyncSession,
    user: User,
    request: Request,
) -> TokenResponse:
    """Issue access and refresh tokens for user.

    Args:
        db: Database session
        user: Authenticated user
        request: HTTP request for metadata

    Returns:
        Token response with access and refresh tokens
    """
    token_repo = RefreshTokenRepository(db)

    # Create tokens
    jwt_access_token = create_access_token(user.id, user.tenant_id)
    jwt_refresh_token = create_refresh_token(user.id, user.tenant_id)
    expires_at = get_token_expiration()

    # Store refresh token
    stored_token = RefreshToken(
        user_id=user.id,
        token_hash=hash_token(jwt_refresh_token),
        expires_at=expires_at,
        user_agent=request.headers.get("User-Agent"),
        ip_address=request.client.host if request.client else None,
    )
    await token_repo.create(stored_token)

    return TokenResponse(
        access_token=jwt_access_token,
        refresh_token=jwt_refresh_token,
        expires_in=settings.access_token_expire_minutes * 60,
    )


# ============================================================
# Route Handlers
# ============================================================


@router.get(
    "/providers",
    response_model=OAuthProvidersResponse,
    summary="List OAuth providers",
    description="Returns list of configured OAuth providers.",
)
async def list_providers() -> OAuthProvidersResponse:
    """List available OAuth providers."""
    return OAuthProvidersResponse(providers=get_available_providers())


@router.get(
    "/{provider}/authorize",
    response_model=OAuthAuthorizeResponse,
    summary="Get OAuth authorization URL",
    description="Returns the URL to redirect the user to for OAuth authorization.",
)
async def authorize(
    provider: str,
    request: Request,
    redirect_uri: str | None = Query(
        None,
        description="Custom redirect URI (defaults to callback endpoint)",
    ),
) -> OAuthAuthorizeResponse:
    """Get OAuth authorization URL."""
    oauth_provider = _get_oauth_provider(provider)

    # Generate state for CSRF protection
    state = generate_state()

    # Build callback URL
    if redirect_uri:
        callback_url = redirect_uri
    else:
        callback_url = str(request.url_for("oauth_callback", provider=provider))

    # Store state in Redis with TTL
    await store_oauth_state(
        state,
        OAuthStateData(provider=provider, redirect_uri=callback_url),
    )

    # Get authorization URL
    auth_url = oauth_provider.get_authorize_url(callback_url, state)

    logger.info(
        "oauth_authorize_initiated",
        provider=provider,
        state=state[:8] + "...",
    )

    return OAuthAuthorizeResponse(url=auth_url, state=state)


@router.get(
    "/{provider}/callback",
    response_model=TokenResponse,
    summary="OAuth callback",
    description="Handle OAuth provider callback after authorization.",
)
async def oauth_callback(
    provider: str,
    request: Request,
    db: DBSession,
    code: str | None = Query(None, description="Authorization code from provider"),
    state: str = Query(..., description="State parameter for CSRF verification"),
    error: str | None = Query(None, description="Error from provider"),
    error_description: str | None = Query(None, description="Error description"),
) -> TokenResponse:
    """Handle OAuth callback.

    This endpoint handles the callback from OAuth providers after user authorization.
    It validates the state, exchanges the code for tokens, and creates/links the user.
    """
    # Check for errors from provider
    if error:
        logger.warning(
            "oauth_callback_error",
            provider=provider,
            error=error,
            description=error_description,
        )
        raise BadRequestError(
            error_description or f"OAuth error: {error}",
            error_code="oauth_error",
        )

    # Validate that code is provided
    if not code:
        raise BadRequestError(
            "Authorization code is required",
            error_code="missing_code",
        )

    # Step 1: Verify state (CSRF protection)
    state_data = await _verify_state(state, provider)

    # Step 2: Get provider
    oauth_provider = _get_oauth_provider(provider)

    # Step 3: Exchange code for user info
    user_info = await _exchange_code_for_user_info(
        oauth_provider,
        code,
        state_data["redirect_uri"],
        provider,
    )

    # Step 4: Find or create user
    user = await _find_or_create_user(db, user_info, provider)

    # Step 5: Check if user is active
    if not user.is_active:
        raise BadRequestError(
            "User account is deactivated",
            error_code="account_inactive",
        )

    # Step 6: Issue tokens
    token_response = await _issue_tokens(db, user, request)

    logger.info(
        "oauth_login_success",
        user_id=str(user.id),
        provider=provider,
    )

    return token_response
