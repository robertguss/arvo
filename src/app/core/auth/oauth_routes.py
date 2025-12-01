"""OAuth2 API routes.

Provides endpoints for OAuth authentication flow:
- Initiate authorization
- Handle callback
- Link/unlink accounts
"""

import re

import structlog
from fastapi import APIRouter, Query, Request
from pydantic import BaseModel

from app.api.dependencies import DBSession
from app.config import settings
from app.core.auth.backend import (
    create_access_token,
    create_refresh_token,
    get_token_expiration,
    hash_token,
)
from app.core.auth.oauth import (
    generate_state,
    get_available_providers,
    get_provider,
)
from app.core.errors import BadRequestError, NotFoundError
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


# In-memory state storage (use Redis in production for horizontal scaling)
# This is acceptable for single-instance deployments
_oauth_states: dict[str, dict] = {}


def _generate_slug(name: str) -> str:
    """Generate URL-safe slug from name."""
    slug = name.lower().strip()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"[-\s]+", "-", slug)
    return slug[:63]


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
    oauth_provider = get_provider(provider)
    if not oauth_provider:
        raise NotFoundError(
            f"OAuth provider '{provider}' not configured",
            resource="oauth_provider",
            resource_id=provider,
        )

    # Generate state for CSRF protection
    state = generate_state()

    # Build callback URL
    if redirect_uri:
        callback_url = redirect_uri
    else:
        callback_url = str(request.url_for("oauth_callback", provider=provider))

    # Store state with metadata
    _oauth_states[state] = {
        "provider": provider,
        "redirect_uri": callback_url,
    }

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
    code: str = Query(..., description="Authorization code from provider"),
    state: str = Query(..., description="State parameter for CSRF verification"),
    error: str | None = Query(None, description="Error from provider"),
    error_description: str | None = Query(None, description="Error description"),
) -> TokenResponse:
    """Handle OAuth callback."""
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

    # Verify state
    state_data = _oauth_states.pop(state, None)
    if not state_data:
        raise BadRequestError(
            "Invalid or expired OAuth state",
            error_code="invalid_state",
        )

    if state_data["provider"] != provider:
        raise BadRequestError(
            "OAuth state mismatch",
            error_code="state_mismatch",
        )

    # Get provider
    oauth_provider = get_provider(provider)
    if not oauth_provider:
        raise NotFoundError(
            f"OAuth provider '{provider}' not configured",
            resource="oauth_provider",
            resource_id=provider,
        )

    try:
        # Exchange code for tokens
        token_response = await oauth_provider.exchange_code(
            code,
            state_data["redirect_uri"],
        )

        # Get user info
        access_token = token_response.get("access_token")
        if not access_token:
            raise BadRequestError(
                "No access token in OAuth response",
                error_code="missing_token",
            )

        user_info = await oauth_provider.get_user_info(access_token)

    except Exception as e:
        logger.exception("oauth_callback_failed", provider=provider)
        raise BadRequestError(
            f"OAuth authentication failed: {e!s}",
            error_code="oauth_failed",
        ) from None

    # Find or create user
    user_repo = UserRepository(db)
    token_repo = RefreshTokenRepository(db)

    # Try to find by OAuth ID
    user = await user_repo.get_by_oauth(provider, user_info.provider_id)

    if not user:
        # Try to find by email (could be existing user)
        user = await user_repo.get_by_email(user_info.email)

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
        else:
            # Create new tenant and user
            tenant = Tenant(
                name=f"{user_info.name}'s Workspace",
                slug=_generate_slug(user_info.name),
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

    # Check if user is active
    if not user.is_active:
        raise BadRequestError(
            "User account is deactivated",
            error_code="account_inactive",
        )

    # Create tokens
    jwt_access_token = create_access_token(user.id, user.tenant_id)
    jwt_refresh_token = create_refresh_token(user.id, user.tenant_id)
    expires_at = get_token_expiration()

    # Store refresh token
    stored_token = RefreshToken(
        user_id=user.id,
        token_hash=hash_token(jwt_refresh_token),
        expires_at=expires_at.isoformat(),
        user_agent=request.headers.get("User-Agent"),
        ip_address=request.client.host if request.client else None,
    )
    await token_repo.create(stored_token)

    logger.info(
        "oauth_login_success",
        user_id=str(user.id),
        provider=provider,
    )

    return TokenResponse(
        access_token=jwt_access_token,
        refresh_token=jwt_refresh_token,
        expires_in=settings.access_token_expire_minutes * 60,
    )

