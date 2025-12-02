"""Authentication module for JWT and password handling."""

from app.core.auth.backend import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    hash_token,
    verify_password,
)
from app.core.auth.dependencies import (
    CurrentActiveUser,
    CurrentSuperuser,
    CurrentUser,
    OptionalUser,
    TenantId,
    get_current_user,
    get_tenant_id,
)
from app.core.auth.middleware import RequestIdMiddleware, TenantContextMiddleware
from app.core.auth.oauth import get_available_providers, get_provider
from app.core.auth.oauth_routes import router as oauth_router
from app.core.auth.routes import router as auth_router
from app.core.auth.schemas import TokenData, TokenPair
from app.core.auth.service import AuthService


__all__ = [
    # Service
    "AuthService",
    # Dependencies
    "CurrentActiveUser",
    "CurrentSuperuser",
    "CurrentUser",
    "OptionalUser",
    # Middleware
    "RequestIdMiddleware",
    "TenantContextMiddleware",
    "TenantId",
    # Schemas
    "TokenData",
    "TokenPair",
    # Routers
    "auth_router",
    # Token utilities
    "create_access_token",
    "create_refresh_token",
    "decode_token",
    # OAuth
    "get_available_providers",
    "get_current_user",
    "get_provider",
    "get_tenant_id",
    # Password utilities
    "hash_password",
    "hash_token",
    "oauth_router",
    "verify_password",
]
