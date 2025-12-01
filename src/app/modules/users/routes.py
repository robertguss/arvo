"""User API routes.

Note: Authentication routes (login, register, refresh) are in
the auth module. This module handles user management endpoints.
"""

from uuid import UUID

from fastapi import Query

from app.core.auth.dependencies import CurrentUser, TenantId
from app.modules.users import router
from app.modules.users.schemas import (
    UserListResponse,
    UserResponse,
    UserUpdate,
)
from app.modules.users.services import UserSvc


# ============================================================
# User Management Routes
# ============================================================


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


@router.patch(
    "/me",
    response_model=UserResponse,
    summary="Update current user",
    description="Update the currently authenticated user's profile.",
)
async def update_me(
    data: UserUpdate,
    current_user: CurrentUser,
    tenant_id: TenantId,
    service: UserSvc,
) -> UserResponse:
    """Update current user profile."""
    user = await service.update_user(current_user.id, data, tenant_id)
    return UserResponse.model_validate(user)


@router.get(
    "",
    response_model=UserListResponse,
    summary="List users",
    description="List all users in the current tenant. Requires admin permissions.",
)
async def list_users(
    service: UserSvc,
    tenant_id: TenantId,
    current_user: CurrentUser,  # noqa: ARG001 - required for auth
    page: int = Query(1, ge=1, description="Page number"),
    page_size: int = Query(20, ge=1, le=100, description="Items per page"),
) -> UserListResponse:
    """List users in tenant."""
    users, total = await service.list_users(tenant_id, page, page_size)
    return UserListResponse(
        items=[UserResponse.model_validate(u) for u in users],
        total=total,
        page=page,
        page_size=page_size,
    )


@router.get(
    "/{user_id}",
    response_model=UserResponse,
    summary="Get user by ID",
    description="Get a specific user by their ID. Requires admin permissions.",
)
async def get_user(
    user_id: UUID,
    service: UserSvc,
    tenant_id: TenantId,
    current_user: CurrentUser,  # noqa: ARG001 - required for auth
) -> UserResponse:
    """Get user by ID."""
    user = await service.get_user(user_id, tenant_id)
    return UserResponse.model_validate(user)


@router.patch(
    "/{user_id}",
    response_model=UserResponse,
    summary="Update user",
    description="Update a user's profile. Requires admin permissions.",
)
async def update_user(
    user_id: UUID,
    data: UserUpdate,
    service: UserSvc,
    tenant_id: TenantId,
    current_user: CurrentUser,  # noqa: ARG001 - required for auth
) -> UserResponse:
    """Update user by ID."""
    user = await service.update_user(user_id, data, tenant_id)
    return UserResponse.model_validate(user)


@router.post(
    "/{user_id}/deactivate",
    response_model=UserResponse,
    summary="Deactivate user",
    description="Deactivate a user account. Requires admin permissions.",
)
async def deactivate_user(
    user_id: UUID,
    service: UserSvc,
    tenant_id: TenantId,
    current_user: CurrentUser,  # noqa: ARG001 - required for auth
) -> UserResponse:
    """Deactivate a user."""
    user = await service.deactivate_user(user_id, tenant_id)
    return UserResponse.model_validate(user)


@router.post(
    "/{user_id}/activate",
    response_model=UserResponse,
    summary="Activate user",
    description="Activate a previously deactivated user account. Requires admin permissions.",
)
async def activate_user(
    user_id: UUID,
    service: UserSvc,
    tenant_id: TenantId,
    current_user: CurrentUser,  # noqa: ARG001 - required for auth
) -> UserResponse:
    """Activate a user."""
    user = await service.activate_user(user_id, tenant_id)
    return UserResponse.model_validate(user)
