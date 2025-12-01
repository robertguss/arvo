"""Authentication schemas for token handling."""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class TokenData(BaseModel):
    """Data extracted from a JWT token.

    Attributes:
        user_id: The user's UUID
        tenant_id: The tenant's UUID
        exp: Token expiration time
        type: Token type (access or refresh)
    """

    user_id: UUID
    tenant_id: UUID
    exp: datetime
    type: str = "access"


class TokenPair(BaseModel):
    """A pair of access and refresh tokens.

    Attributes:
        access_token: Short-lived JWT for API access
        refresh_token: Long-lived token for getting new access tokens
        token_type: Always "bearer"
        expires_in: Access token expiration in seconds
    """

    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int

