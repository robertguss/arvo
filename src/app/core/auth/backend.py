"""Authentication backend for JWT and password handling.

This module provides core authentication utilities including:
- Password hashing with bcrypt
- JWT token creation and verification
- Token hashing for storage
- Token revocation
"""

import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

from jose import JWTError, jwt
from passlib.context import CryptContext

from app.config import settings
from app.core.auth.schemas import TokenData
from app.core.constants import ACCESS_TOKEN_JTI_LENGTH


# Password hashing context using bcrypt
# truncate_error=False allows bcrypt to work with newer versions
pwd_context = CryptContext(
    schemes=["bcrypt"],
    deprecated="auto",
    bcrypt__rounds=12,
)


# ============================================================
# Password Utilities
# ============================================================


def hash_password(password: str) -> str:
    """Hash a password using bcrypt.

    Args:
        password: Plain text password

    Returns:
        Bcrypt hash of the password
    """
    return pwd_context.hash(password)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    """Verify a password against its hash.

    Args:
        plain_password: Plain text password to verify
        hashed_password: Bcrypt hash to verify against

    Returns:
        True if password matches, False otherwise
    """
    return pwd_context.verify(plain_password, hashed_password)


# ============================================================
# JWT Token Utilities
# ============================================================


def create_access_token(
    user_id: UUID,
    tenant_id: UUID,
    expires_delta: timedelta | None = None,
    additional_claims: dict[str, Any] | None = None,
) -> str:
    """Create a short-lived JWT access token.

    Args:
        user_id: The user's UUID
        tenant_id: The tenant's UUID
        expires_delta: Optional custom expiration time
        additional_claims: Optional extra claims to include

    Returns:
        Encoded JWT access token
    """
    if expires_delta:
        expire = datetime.now(UTC) + expires_delta
    else:
        expire = datetime.now(UTC) + timedelta(
            minutes=settings.access_token_expire_minutes
        )

    to_encode: dict[str, Any] = {
        "sub": str(user_id),
        "tenant_id": str(tenant_id),
        "exp": expire,
        "type": "access",
        "iat": datetime.now(UTC),
        "jti": secrets.token_urlsafe(ACCESS_TOKEN_JTI_LENGTH),  # Unique token ID
    }

    if additional_claims:
        to_encode.update(additional_claims)

    return jwt.encode(
        to_encode,
        settings.secret_key,
        algorithm=settings.jwt_algorithm,
    )


def create_refresh_token(
    user_id: UUID,  # noqa: ARG001
    tenant_id: UUID,  # noqa: ARG001
    expires_delta: timedelta | None = None,  # noqa: ARG001
) -> str:
    """Create a long-lived refresh token.

    The refresh token is a random string (not a JWT) for better security.
    It should be stored hashed in the database.

    Args:
        user_id: The user's UUID
        tenant_id: The tenant's UUID
        expires_delta: Optional custom expiration time

    Returns:
        Random refresh token string
    """
    # Generate a secure random token
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    """Hash a token for secure storage.

    Uses SHA-256 to hash tokens before storing in the database.
    This prevents token theft if the database is compromised.

    Args:
        token: The token to hash

    Returns:
        SHA-256 hash of the token
    """
    return hashlib.sha256(token.encode()).hexdigest()


def decode_token(token: str) -> TokenData | None:
    """Decode and validate a JWT token.

    Args:
        token: The JWT token to decode

    Returns:
        TokenData if valid, None if invalid or expired
    """
    try:
        payload = jwt.decode(
            token,
            settings.secret_key,
            algorithms=[settings.jwt_algorithm],
        )

        user_id = payload.get("sub")
        tenant_id = payload.get("tenant_id")
        exp = payload.get("exp")
        token_type = payload.get("type", "access")
        jti = payload.get("jti")

        if not user_id or not tenant_id or exp is None:
            return None

        return TokenData(
            user_id=UUID(user_id),
            tenant_id=UUID(tenant_id),
            exp=datetime.fromtimestamp(exp, tz=UTC),
            type=token_type,
            jti=jti,
        )

    except (JWTError, ValueError):
        return None


def get_token_expiration(days: int | None = None) -> datetime:
    """Get the expiration datetime for a refresh token.

    Args:
        days: Number of days until expiration

    Returns:
        Expiration datetime
    """
    if days is None:
        days = settings.refresh_token_expire_days
    return datetime.now(UTC) + timedelta(days=days)

