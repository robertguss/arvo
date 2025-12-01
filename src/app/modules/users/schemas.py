"""Pydantic schemas for user operations."""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field


# ============================================================
# User Schemas
# ============================================================


class UserBase(BaseModel):
    """Base schema for user data."""

    email: EmailStr
    full_name: str = Field(..., min_length=1, max_length=255)


class UserCreate(UserBase):
    """Schema for creating a new user with password."""

    password: str = Field(..., min_length=8, max_length=128)


class UserCreateOAuth(BaseModel):
    """Schema for creating a user via OAuth."""

    email: EmailStr
    full_name: str = Field(..., min_length=1, max_length=255)
    oauth_provider: str
    oauth_id: str


class UserUpdate(BaseModel):
    """Schema for updating user data."""

    email: EmailStr | None = None
    full_name: str | None = Field(None, min_length=1, max_length=255)


class UserPasswordUpdate(BaseModel):
    """Schema for updating user password."""

    current_password: str
    new_password: str = Field(..., min_length=8, max_length=128)


class UserResponse(UserBase):
    """Schema for user response data."""

    id: UUID
    tenant_id: UUID
    is_active: bool
    is_superuser: bool
    oauth_provider: str | None = None
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class UserListResponse(BaseModel):
    """Schema for listing users."""

    items: list[UserResponse]
    total: int
    page: int
    page_size: int


# ============================================================
# Authentication Schemas
# ============================================================


class LoginRequest(BaseModel):
    """Schema for email/password login."""

    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    """Schema for authentication token response."""

    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int = Field(..., description="Access token expiration in seconds")


class RefreshTokenRequest(BaseModel):
    """Schema for refreshing access token."""

    refresh_token: str


class AccessTokenResponse(BaseModel):
    """Schema for refreshed access token."""

    access_token: str
    token_type: str = "bearer"
    expires_in: int


# ============================================================
# Registration Schemas
# ============================================================


class RegisterRequest(BaseModel):
    """Schema for user registration.

    Creates both a new tenant and user in one request.
    """

    email: EmailStr
    password: str = Field(..., min_length=8, max_length=128)
    full_name: str = Field(..., min_length=1, max_length=255)
    tenant_name: str = Field(..., min_length=1, max_length=255)


class RegisterResponse(BaseModel):
    """Schema for registration response."""

    user: UserResponse
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int

