"""Unit tests for auth backend (JWT and password handling)."""

from datetime import timedelta
from uuid import uuid4

import pytest

from app.core.auth.backend import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    hash_token,
    verify_password,
)


class TestPasswordHashing:
    """Tests for password hashing functions."""

    def test_hash_password_returns_hash(self):
        """hash_password should return a bcrypt hash."""
        password = "mysecretpassword"
        hashed = hash_password(password)

        assert hashed != password
        assert hashed.startswith("$2b$")  # bcrypt prefix

    def test_hash_password_different_each_time(self):
        """hash_password should produce different hashes for same password."""
        password = "mysecretpassword"
        hash1 = hash_password(password)
        hash2 = hash_password(password)

        # Different due to random salt
        assert hash1 != hash2

    def test_verify_password_correct(self):
        """verify_password should return True for correct password."""
        password = "mysecretpassword"
        hashed = hash_password(password)

        assert verify_password(password, hashed) is True

    def test_verify_password_incorrect(self):
        """verify_password should return False for incorrect password."""
        password = "mysecretpassword"
        hashed = hash_password(password)

        assert verify_password("wrongpassword", hashed) is False


class TestJWTTokens:
    """Tests for JWT token functions."""

    def test_create_access_token_returns_string(self):
        """create_access_token should return a JWT string."""
        user_id = uuid4()
        tenant_id = uuid4()

        token = create_access_token(user_id, tenant_id)

        assert isinstance(token, str)
        assert len(token) > 0
        # JWT has three parts separated by dots
        assert token.count(".") == 2

    def test_create_access_token_custom_expiry(self):
        """create_access_token should accept custom expiration."""
        user_id = uuid4()
        tenant_id = uuid4()

        token = create_access_token(
            user_id,
            tenant_id,
            expires_delta=timedelta(hours=1),
        )

        assert isinstance(token, str)

    def test_decode_token_valid(self):
        """decode_token should decode a valid token."""
        user_id = uuid4()
        tenant_id = uuid4()

        token = create_access_token(user_id, tenant_id)
        data = decode_token(token)

        assert data is not None
        assert data.user_id == user_id
        assert data.tenant_id == tenant_id
        assert data.type == "access"

    def test_decode_token_invalid(self):
        """decode_token should return None for invalid token."""
        data = decode_token("invalid.token.here")

        assert data is None

    def test_decode_token_expired(self):
        """decode_token should return None for expired token."""
        user_id = uuid4()
        tenant_id = uuid4()

        # Create token that expired in the past
        token = create_access_token(
            user_id,
            tenant_id,
            expires_delta=timedelta(seconds=-10),
        )
        data = decode_token(token)

        assert data is None

    def test_create_refresh_token_returns_string(self):
        """create_refresh_token should return a random string."""
        user_id = uuid4()
        tenant_id = uuid4()

        token = create_refresh_token(user_id, tenant_id)

        assert isinstance(token, str)
        assert len(token) > 20  # Should be reasonably long

    def test_create_refresh_token_unique(self):
        """create_refresh_token should generate unique tokens."""
        user_id = uuid4()
        tenant_id = uuid4()

        token1 = create_refresh_token(user_id, tenant_id)
        token2 = create_refresh_token(user_id, tenant_id)

        assert token1 != token2


class TestTokenHashing:
    """Tests for token hashing functions."""

    def test_hash_token_returns_hex(self):
        """hash_token should return a hex string."""
        token = "myrefreshtoken123"
        hashed = hash_token(token)

        assert isinstance(hashed, str)
        assert len(hashed) == 64  # SHA-256 produces 64 hex chars

    def test_hash_token_consistent(self):
        """hash_token should produce the same hash for same token."""
        token = "myrefreshtoken123"

        hash1 = hash_token(token)
        hash2 = hash_token(token)

        assert hash1 == hash2

    def test_hash_token_different_for_different_tokens(self):
        """hash_token should produce different hashes for different tokens."""
        hash1 = hash_token("token1")
        hash2 = hash_token("token2")

        assert hash1 != hash2

