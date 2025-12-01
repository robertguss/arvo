"""User factory for tests."""

from uuid import uuid4

from polyfactory.factories.pydantic_factory import ModelFactory

from app.modules.users.models import RefreshToken, User
from app.modules.users.schemas import UserCreate


class UserFactory(ModelFactory):
    """Factory for creating test User instances."""

    __model__ = User

    @classmethod
    def email(cls) -> str:
        """Generate a unique email."""
        return f"user-{uuid4().hex[:8]}@example.com"

    @classmethod
    def full_name(cls) -> str:
        """Generate a full name."""
        return f"Test User {uuid4().hex[:4]}"

    @classmethod
    def password_hash(cls) -> str:
        """Generate a password hash (bcrypt)."""
        # This is a bcrypt hash of "testpassword123"
        return "$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/X4.xzQvGxRGlKHOHO"

    @classmethod
    def tenant_id(cls):
        """Generate a tenant ID."""
        return uuid4()

    @classmethod
    def is_active(cls) -> bool:
        """Default to active."""
        return True

    @classmethod
    def is_superuser(cls) -> bool:
        """Default to non-superuser."""
        return False


class UserCreateFactory(ModelFactory):
    """Factory for creating UserCreate schemas."""

    __model__ = UserCreate

    @classmethod
    def email(cls) -> str:
        """Generate a unique email."""
        return f"user-{uuid4().hex[:8]}@example.com"

    @classmethod
    def full_name(cls) -> str:
        """Generate a full name."""
        return f"Test User {uuid4().hex[:4]}"

    @classmethod
    def password(cls) -> str:
        """Generate a password."""
        return "testpassword123"


class RefreshTokenFactory(ModelFactory):
    """Factory for creating test RefreshToken instances."""

    __model__ = RefreshToken

    @classmethod
    def user_id(cls):
        """Generate a user ID."""
        return uuid4()

    @classmethod
    def token_hash(cls) -> str:
        """Generate a token hash."""
        return uuid4().hex * 2  # 64 chars like SHA-256

    @classmethod
    def expires_at(cls) -> str:
        """Generate expiration time."""
        from datetime import datetime, timedelta, timezone

        return (datetime.now(timezone.utc) + timedelta(days=7)).isoformat()

    @classmethod
    def revoked(cls) -> bool:
        """Default to not revoked."""
        return False

