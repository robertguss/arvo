"""Authentication API routes.

Provides endpoints for:
- User registration
- Login/logout
- Token refresh
- OAuth callbacks
"""

from fastapi import APIRouter, Request, status

from app.core.auth.dependencies import CurrentUser
from app.core.auth.service import AuthSvc
from app.modules.users.schemas import (
    LoginRequest,
    RefreshTokenRequest,
    RegisterRequest,
    RegisterResponse,
    TokenResponse,
    UserResponse,
)


router = APIRouter(prefix="/auth", tags=["auth"])


def _get_client_info(request: Request) -> tuple[str | None, str | None]:
    """Extract client info from request."""
    user_agent = request.headers.get("User-Agent")
    # Get IP from X-Forwarded-For or client host
    ip_address: str | None = None
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        ip_address = forwarded.split(",")[0].strip()
    elif request.client:
        ip_address = request.client.host
    return user_agent, ip_address


@router.post(
    "/register",
    response_model=RegisterResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Register new user and tenant",
    description="Creates a new tenant and user account. The user becomes the tenant's superuser.",
)
async def register(
    data: RegisterRequest,
    service: AuthSvc,
    request: Request,  # noqa: ARG001
) -> RegisterResponse:
    """Register a new user and tenant."""
    user, tokens = await service.register(
        email=data.email,
        password=data.password,
        full_name=data.full_name,
        tenant_name=data.tenant_name,
    )

    return RegisterResponse(
        user=UserResponse.model_validate(user),
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
    )


@router.post(
    "/login",
    response_model=TokenResponse,
    summary="Login with email and password",
    description="Authenticate with email and password to receive access and refresh tokens.",
)
async def login(
    data: LoginRequest,
    service: AuthSvc,
    request: Request,
) -> TokenResponse:
    """Login with email and password."""
    user_agent, ip_address = _get_client_info(request)

    _user, tokens = await service.login(
        email=data.email,
        password=data.password,
        user_agent=user_agent,
        ip_address=ip_address,
    )

    return TokenResponse(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
    )


@router.post(
    "/refresh",
    response_model=TokenResponse,
    summary="Refresh access token",
    description="Use a refresh token to obtain a new access token. The old refresh token is revoked.",
)
async def refresh_token(
    data: RefreshTokenRequest,
    service: AuthSvc,
    request: Request,
) -> TokenResponse:
    """Refresh the access token."""
    user_agent, ip_address = _get_client_info(request)

    tokens = await service.refresh_tokens(
        refresh_token=data.refresh_token,
        user_agent=user_agent,
        ip_address=ip_address,
    )

    return TokenResponse(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
    )


@router.post(
    "/logout",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Logout",
    description="Revoke the refresh token to logout from the current session.",
)
async def logout(
    data: RefreshTokenRequest,
    service: AuthSvc,
) -> None:
    """Logout by revoking the refresh token."""
    await service.logout(data.refresh_token)


@router.post(
    "/logout-all",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Logout from all devices",
    description="Revoke all refresh tokens to logout from all devices.",
)
async def logout_all(
    current_user: CurrentUser,
    service: AuthSvc,
) -> None:
    """Logout from all devices."""
    await service.logout_all(current_user.id)


@router.get(
    "/me",
    response_model=UserResponse,
    summary="Get current user",
    description="Returns the currently authenticated user's profile.",
)
async def get_me(
    current_user: CurrentUser,
) -> UserResponse:
    """Get current user profile."""
    return UserResponse.model_validate(current_user)
