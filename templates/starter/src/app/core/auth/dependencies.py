"""FastAPI dependencies for authentication.

This module provides FastAPI dependency injection functions for:
- Extracting and validating JWT tokens
- Getting the current authenticated user
- Getting the current tenant context
"""

from typing import TYPE_CHECKING, Annotated
from uuid import UUID

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.api.dependencies import DBSession
from app.core.auth.backend import decode_token
from app.core.auth.schemas import TokenData
from app.core.errors import ForbiddenError, UnauthorizedError


if TYPE_CHECKING:
    from app.modules.users.models import User


# HTTP Bearer token security scheme
bearer_scheme = HTTPBearer(auto_error=False)


async def get_token_data(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    db: DBSession,
) -> TokenData:
    """Extract and validate token data from the Authorization header.

    Args:
        credentials: Bearer token credentials from the request
        db: Database session for revocation check

    Returns:
        Decoded token data

    Raises:
        UnauthorizedError: If token is missing, invalid, or revoked
    """
    if not credentials:
        raise UnauthorizedError(
            "Missing authentication token",
            error_code="missing_token",
        )

    token_data = decode_token(credentials.credentials)
    if not token_data:
        raise UnauthorizedError(
            "Invalid or expired token",
            error_code="invalid_token",
        )

    if token_data.type != "access":
        raise UnauthorizedError(
            "Invalid token type",
            error_code="invalid_token_type",
        )

    # Check if token has been revoked
    if token_data.jti:
        from app.modules.users.repos import RevokedTokenRepository

        revoked_repo = RevokedTokenRepository(db)
        if await revoked_repo.is_revoked(token_data.jti):
            raise UnauthorizedError(
                "Token has been revoked",
                error_code="token_revoked",
            )

    return token_data


async def get_current_user(
    token_data: Annotated[TokenData, Depends(get_token_data)],
    db: DBSession,
) -> "User":
    """Get the currently authenticated user.

    Args:
        token_data: Validated token data
        db: Database session

    Returns:
        The authenticated user

    Raises:
        UnauthorizedError: If user not found or inactive
    """
    from app.modules.users.repos import UserRepository

    repo = UserRepository(db)
    # Use tenant-scoped lookup for security
    user = await repo.get_by_id(token_data.user_id, token_data.tenant_id)

    if not user:
        raise UnauthorizedError(
            "User not found",
            error_code="user_not_found",
        )

    if not user.is_active:
        raise ForbiddenError(
            "User account is deactivated",
            error_code="user_inactive",
        )

    return user


async def get_current_active_user(
    user: Annotated["User", Depends(get_current_user)],
) -> "User":
    """Get the current user, ensuring they are active.

    This is an alias for get_current_user that makes the intent explicit.
    The actual check is done in get_current_user.

    Args:
        user: The current user

    Returns:
        The active user
    """
    return user


async def get_current_superuser(
    user: Annotated["User", Depends(get_current_user)],
) -> "User":
    """Get the current user, ensuring they are a superuser.

    Args:
        user: The current user

    Returns:
        The superuser

    Raises:
        ForbiddenError: If user is not a superuser
    """
    if not user.is_superuser:
        raise ForbiddenError(
            "Superuser privileges required",
            error_code="not_superuser",
        )
    return user


async def get_tenant_id(
    token_data: Annotated[TokenData, Depends(get_token_data)],
) -> UUID:
    """Get the current tenant ID from the token.

    Args:
        token_data: Validated token data

    Returns:
        The tenant UUID
    """
    return token_data.tenant_id


# Type aliases for cleaner dependency injection
# Using string annotations for forward references to avoid circular imports
CurrentUser = Annotated["User", Depends(get_current_user)]
CurrentActiveUser = Annotated["User", Depends(get_current_active_user)]
CurrentSuperuser = Annotated["User", Depends(get_current_superuser)]
TenantId = Annotated[UUID, Depends(get_tenant_id)]


async def get_optional_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    db: DBSession,
) -> "User | None":
    """Get the current user if authenticated, None otherwise.

    Useful for endpoints that work with or without authentication.

    Args:
        credentials: Optional bearer token credentials
        db: Database session

    Returns:
        User if authenticated, None otherwise
    """
    if not credentials:
        return None

    token_data = decode_token(credentials.credentials)
    if not token_data or token_data.type != "access":
        return None

    # Check if token has been revoked
    if token_data.jti:
        from app.modules.users.repos import RevokedTokenRepository

        revoked_repo = RevokedTokenRepository(db)
        if await revoked_repo.is_revoked(token_data.jti):
            return None

    from app.modules.users.repos import UserRepository

    repo = UserRepository(db)
    # Use tenant-scoped lookup for security
    user = await repo.get_by_id(token_data.user_id, token_data.tenant_id)

    if not user or not user.is_active:
        return None

    return user


OptionalUser = Annotated["User | None", Depends(get_optional_user)]
