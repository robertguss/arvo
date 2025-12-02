"""Unit tests for AuthService."""

from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest

from app.core.auth.service import AuthService
from app.core.errors import ConflictError, UnauthorizedError
from app.modules.users.models import RefreshToken, User


def make_mock_user(
    user_id=None,
    tenant_id=None,
    email="test@example.com",
    password_hash="hashedpwd",
    is_active=True,
):
    """Create a mock User for testing."""
    user = MagicMock(spec=User)
    user.id = user_id or uuid4()
    user.tenant_id = tenant_id or uuid4()
    user.email = email
    user.password_hash = password_hash
    user.is_active = is_active
    return user


class TestAuthServiceRegister:
    """Tests for AuthService.register method."""

    @pytest.mark.asyncio
    async def test_register_success(self):
        """Verify successful registration creates tenant, user, and tokens."""
        mock_db = AsyncMock()
        mock_db.add = MagicMock()
        mock_db.flush = AsyncMock()

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.hash_password") as mock_hash_pwd,
            patch("app.core.auth.service.generate_slug") as mock_slug,
            patch("app.core.auth.service.create_access_token") as mock_access,
            patch("app.core.auth.service.create_refresh_token") as mock_refresh,
            patch("app.core.auth.service.get_token_expiration") as mock_exp,
            patch("app.core.auth.service.hash_token") as mock_hash,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_email_system.return_value = None
            created_user = make_mock_user(email="new@example.com")
            mock_user_repo.create.return_value = created_user
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo_cls.return_value = mock_token_repo

            mock_hash_pwd.return_value = "hashed_password"
            mock_slug.return_value = "test-tenant"
            mock_access.return_value = "access_token"
            mock_refresh.return_value = "refresh_token"
            mock_exp.return_value = datetime.now(UTC) + timedelta(days=7)
            mock_hash.return_value = "hashed_refresh"

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            user, token_pair = await service.register(
                email="new@example.com",
                password="password123",
                full_name="New User",
                tenant_name="Test Tenant",
            )

            assert user == created_user
            assert token_pair.access_token == "access_token"
            mock_db.add.assert_called_once()  # Tenant added
            mock_user_repo.create.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_register_duplicate_email_raises_conflict(self):
        """Verify ConflictError when email already exists."""
        mock_db = AsyncMock()
        existing_user = make_mock_user(email="exists@example.com")

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_email_system.return_value = existing_user
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo_cls.return_value = mock_token_repo

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            with pytest.raises(ConflictError) as exc_info:
                await service.register(
                    email="exists@example.com",
                    password="password123",
                    full_name="New User",
                    tenant_name="Test Tenant",
                )

            assert exc_info.value.error_code == "registration_failed"


class TestAuthServiceLogin:
    """Tests for AuthService.login method."""

    @pytest.mark.asyncio
    async def test_login_success(self):
        """Verify successful login returns user and tokens."""
        mock_db = AsyncMock()
        mock_user = make_mock_user(password_hash="hashed_password")

        with (
            patch.object(
                AuthService, "__init__", lambda self, db: None
            ),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.verify_password") as mock_verify,
            patch("app.core.auth.service.create_access_token") as mock_access,
            patch("app.core.auth.service.create_refresh_token") as mock_refresh,
            patch("app.core.auth.service.get_token_expiration") as mock_exp,
            patch("app.core.auth.service.hash_token") as mock_hash,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_email_system.return_value = mock_user
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo_cls.return_value = mock_token_repo

            mock_verify.return_value = True
            mock_access.return_value = "access_token"
            mock_refresh.return_value = "refresh_token"
            mock_exp.return_value = datetime.now(UTC) + timedelta(days=7)
            mock_hash.return_value = "hashed_refresh"

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            user, token_pair = await service.login("test@example.com", "password123")

            assert user == mock_user
            assert token_pair.access_token == "access_token"
            assert token_pair.refresh_token == "refresh_token"

    @pytest.mark.asyncio
    async def test_login_user_not_found(self):
        """Verify UnauthorizedError when user doesn't exist."""
        mock_db = AsyncMock()

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.verify_password"),
            patch("app.core.auth.service.hash_password"),
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_email_system.return_value = None
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo_cls.return_value = mock_token_repo

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            with pytest.raises(UnauthorizedError) as exc_info:
                await service.login("nonexistent@example.com", "password")

            assert exc_info.value.error_code == "invalid_credentials"

    @pytest.mark.asyncio
    async def test_login_wrong_password(self):
        """Verify UnauthorizedError when password is wrong."""
        mock_db = AsyncMock()
        mock_user = make_mock_user()

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.verify_password") as mock_verify,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_email_system.return_value = mock_user
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo_cls.return_value = mock_token_repo

            mock_verify.return_value = False

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            with pytest.raises(UnauthorizedError) as exc_info:
                await service.login("test@example.com", "wrong_password")

            assert exc_info.value.error_code == "invalid_credentials"

    @pytest.mark.asyncio
    async def test_login_inactive_user(self):
        """Verify UnauthorizedError when user is inactive."""
        mock_db = AsyncMock()
        mock_user = make_mock_user(is_active=False)

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.verify_password") as mock_verify,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_email_system.return_value = mock_user
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo_cls.return_value = mock_token_repo

            mock_verify.return_value = True

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            with pytest.raises(UnauthorizedError) as exc_info:
                await service.login("test@example.com", "password")

            assert exc_info.value.error_code == "account_inactive"


class TestAuthServiceRefreshTokens:
    """Tests for AuthService.refresh_tokens method."""

    @pytest.mark.asyncio
    async def test_refresh_tokens_success(self):
        """Verify successful token refresh."""
        mock_db = AsyncMock()
        mock_user = make_mock_user()
        mock_stored_token = MagicMock(spec=RefreshToken)
        mock_stored_token.user_id = mock_user.id
        mock_stored_token.expires_at = datetime.now(UTC) + timedelta(days=1)

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.hash_token") as mock_hash,
            patch("app.core.auth.service.create_access_token") as mock_access,
            patch("app.core.auth.service.create_refresh_token") as mock_refresh,
            patch("app.core.auth.service.get_token_expiration") as mock_exp,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_id_system.return_value = mock_user
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo.get_by_hash.return_value = mock_stored_token
            mock_token_repo_cls.return_value = mock_token_repo

            mock_hash.return_value = "hashed_token"
            mock_access.return_value = "new_access_token"
            mock_refresh.return_value = "new_refresh_token"
            mock_exp.return_value = datetime.now(UTC) + timedelta(days=7)

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            token_pair = await service.refresh_tokens("old_refresh_token")

            assert token_pair.access_token == "new_access_token"
            assert token_pair.refresh_token == "new_refresh_token"
            mock_token_repo.revoke.assert_awaited_once_with(mock_stored_token)

    @pytest.mark.asyncio
    async def test_refresh_tokens_invalid_token(self):
        """Verify UnauthorizedError when token not found."""
        mock_db = AsyncMock()

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.hash_token") as mock_hash,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo.get_by_hash.return_value = None
            mock_token_repo_cls.return_value = mock_token_repo

            mock_hash.return_value = "hashed"

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            with pytest.raises(UnauthorizedError) as exc_info:
                await service.refresh_tokens("invalid_token")

            assert exc_info.value.error_code == "invalid_refresh_token"

    @pytest.mark.asyncio
    async def test_refresh_tokens_expired(self):
        """Verify UnauthorizedError when token is expired."""
        mock_db = AsyncMock()
        mock_stored_token = MagicMock(spec=RefreshToken)
        mock_stored_token.expires_at = datetime.now(UTC) - timedelta(hours=1)

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.hash_token") as mock_hash,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo.get_by_hash.return_value = mock_stored_token
            mock_token_repo_cls.return_value = mock_token_repo

            mock_hash.return_value = "hashed"

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            with pytest.raises(UnauthorizedError) as exc_info:
                await service.refresh_tokens("expired_token")

            assert exc_info.value.error_code == "token_expired"

    @pytest.mark.asyncio
    async def test_refresh_tokens_user_not_found(self):
        """Verify UnauthorizedError when user not found."""
        mock_db = AsyncMock()
        mock_stored_token = MagicMock(spec=RefreshToken)
        mock_stored_token.user_id = uuid4()
        mock_stored_token.expires_at = datetime.now(UTC) + timedelta(days=1)

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.hash_token") as mock_hash,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_id_system.return_value = None  # User not found
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo.get_by_hash.return_value = mock_stored_token
            mock_token_repo_cls.return_value = mock_token_repo

            mock_hash.return_value = "hashed"

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            with pytest.raises(UnauthorizedError) as exc_info:
                await service.refresh_tokens("some_token")

            assert exc_info.value.error_code == "user_invalid"

    @pytest.mark.asyncio
    async def test_refresh_tokens_user_inactive(self):
        """Verify UnauthorizedError when user is inactive."""
        mock_db = AsyncMock()
        mock_user = make_mock_user(is_active=False)
        mock_stored_token = MagicMock(spec=RefreshToken)
        mock_stored_token.user_id = mock_user.id
        mock_stored_token.expires_at = datetime.now(UTC) + timedelta(days=1)

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.hash_token") as mock_hash,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_id_system.return_value = mock_user
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo.get_by_hash.return_value = mock_stored_token
            mock_token_repo_cls.return_value = mock_token_repo

            mock_hash.return_value = "hashed"

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            with pytest.raises(UnauthorizedError) as exc_info:
                await service.refresh_tokens("some_token")

            assert exc_info.value.error_code == "user_invalid"


class TestAuthServiceLogout:
    """Tests for AuthService.logout method."""

    @pytest.mark.asyncio
    async def test_logout_revokes_token(self):
        """Verify logout revokes the refresh token."""
        mock_db = AsyncMock()
        mock_stored_token = MagicMock(spec=RefreshToken)

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.hash_token") as mock_hash,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo.get_by_hash.return_value = mock_stored_token
            mock_token_repo_cls.return_value = mock_token_repo

            mock_hash.return_value = "hashed"

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            await service.logout("refresh_token")

            mock_token_repo.revoke.assert_awaited_once_with(mock_stored_token)

    @pytest.mark.asyncio
    async def test_logout_token_not_found(self):
        """Verify logout handles non-existent token gracefully."""
        mock_db = AsyncMock()

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
            patch("app.core.auth.service.hash_token") as mock_hash,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo.get_by_hash.return_value = None
            mock_token_repo_cls.return_value = mock_token_repo

            mock_hash.return_value = "hashed"

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            # Should not raise
            await service.logout("nonexistent_token")

            mock_token_repo.revoke.assert_not_awaited()


class TestAuthServiceLogoutAll:
    """Tests for AuthService.logout_all method."""

    @pytest.mark.asyncio
    async def test_logout_all_revokes_all_tokens(self):
        """Verify logout_all revokes all user tokens."""
        mock_db = AsyncMock()
        user_id = uuid4()

        with (
            patch.object(AuthService, "__init__", lambda self, db: None),
            patch("app.core.auth.service.UserRepository") as mock_user_repo_cls,
            patch("app.core.auth.service.RefreshTokenRepository") as mock_token_repo_cls,
        ):
            mock_user_repo = AsyncMock()
            mock_user_repo_cls.return_value = mock_user_repo

            mock_token_repo = AsyncMock()
            mock_token_repo.revoke_all_for_user.return_value = 5
            mock_token_repo_cls.return_value = mock_token_repo

            service = AuthService.__new__(AuthService)
            service.db = mock_db
            service.user_repo = mock_user_repo
            service.token_repo = mock_token_repo

            count = await service.logout_all(user_id)

            assert count == 5
            mock_token_repo.revoke_all_for_user.assert_awaited_once_with(user_id)
