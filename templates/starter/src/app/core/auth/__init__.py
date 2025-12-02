"""Authentication module for JWT and password handling."""

from app.core.auth.backend import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    hash_token,
    verify_password,
)
from app.core.auth.schemas import TokenData, TokenPair
from app.core.auth.service import AuthService


def get_dependencies():
    """Import dependencies lazily to avoid circular imports."""
    from app.core.auth.dependencies import (
        CurrentActiveUser,
        CurrentSuperuser,
        CurrentUser,
        OptionalUser,
        TenantId,
        get_current_user,
        get_tenant_id,
    )

    return {
        "CurrentActiveUser": CurrentActiveUser,
        "CurrentSuperuser": CurrentSuperuser,
        "CurrentUser": CurrentUser,
        "OptionalUser": OptionalUser,
        "TenantId": TenantId,
        "get_current_user": get_current_user,
        "get_tenant_id": get_tenant_id,
    }


def get_middleware():
    """Import middleware lazily to avoid circular imports."""
    from app.core.auth.middleware import RequestIdMiddleware, TenantContextMiddleware

    return RequestIdMiddleware, TenantContextMiddleware


def get_routers():
    """Import routers lazily to avoid circular imports."""
    from app.core.auth.oauth_routes import router as oauth_router
    from app.core.auth.routes import router as auth_router

    return auth_router, oauth_router


def get_oauth():
    """Import OAuth utilities lazily."""
    from app.core.auth.oauth import get_available_providers, get_provider

    return get_available_providers, get_provider


__all__ = [
    # Service
    "AuthService",
    # Schemas
    "TokenData",
    "TokenPair",
    # Token utilities
    "create_access_token",
    "create_refresh_token",
    "decode_token",
    # Lazy loaders
    "get_dependencies",
    "get_middleware",
    "get_oauth",
    "get_routers",
    # Password utilities
    "hash_password",
    "hash_token",
    "verify_password",
]
