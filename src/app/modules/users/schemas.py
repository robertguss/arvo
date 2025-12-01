"""Pydantic schemas for user operations."""

import re
from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

from app.core.constants import MAX_PASSWORD_LENGTH, MIN_PASSWORD_LENGTH


# ============================================================
# Password Validation
# ============================================================

# Password complexity rules: (regex pattern, human-readable name)
PASSWORD_COMPLEXITY_RULES: list[tuple[str, str]] = [
    (r"[A-Z]", "uppercase letter"),
    (r"[a-z]", "lowercase letter"),
    (r"\d", "digit"),
    (r"[!@#$%^&*(),.?\":{}|<>\[\]\\;'`~_+\-=/]", "special character"),
]


def validate_password_complexity(password: str) -> str:
    """Validate password meets complexity requirements.

    Requirements:
    - At least one uppercase letter
    - At least one lowercase letter
    - At least one digit
    - At least one special character

    Args:
        password: The password to validate

    Returns:
        The validated password

    Raises:
        ValueError: If password doesn't meet requirements
    """
    missing = [
        name
        for pattern, name in PASSWORD_COMPLEXITY_RULES
        if not re.search(pattern, password)
    ]

    if missing:
        if len(missing) == 1:
            raise ValueError(f"Password must contain at least one {missing[0]}")
        raise ValueError(f"Password must contain at least one: {', '.join(missing)}")

    return password


# ============================================================
# User Schemas
# ============================================================


class UserBase(BaseModel):
    """Base schema for user data."""

    email: EmailStr
    full_name: str = Field(..., min_length=1, max_length=255)


class UserCreate(UserBase):
    """Schema for creating a new user with password."""

    password: str = Field(
        ..., min_length=MIN_PASSWORD_LENGTH, max_length=MAX_PASSWORD_LENGTH
    )

    @field_validator("password")
    @classmethod
    def password_complexity(cls, v: str) -> str:
        """Validate password complexity."""
        return validate_password_complexity(v)


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
    new_password: str = Field(
        ..., min_length=MIN_PASSWORD_LENGTH, max_length=MAX_PASSWORD_LENGTH
    )

    @field_validator("new_password")
    @classmethod
    def password_complexity(cls, v: str) -> str:
        """Validate password complexity."""
        return validate_password_complexity(v)


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
    password: str = Field(
        ..., min_length=MIN_PASSWORD_LENGTH, max_length=MAX_PASSWORD_LENGTH
    )
    full_name: str = Field(..., min_length=1, max_length=255)
    tenant_name: str = Field(..., min_length=1, max_length=255)

    @field_validator("password")
    @classmethod
    def password_complexity(cls, v: str) -> str:
        """Validate password complexity."""
        return validate_password_complexity(v)


class RegisterResponse(BaseModel):
    """Schema for registration response."""

    user: UserResponse
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int
