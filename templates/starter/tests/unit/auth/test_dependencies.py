"""Unit tests for auth dependencies."""

from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest
from fastapi.security import HTTPAuthorizationCredentials

from app.core.auth.dependencies import (
    get_current_superuser,
    get_current_user,
    get_optional_user,
    get_tenant_id,
    get_token_data,
)
from app.core.auth.schemas import TokenData
from app.core.errors import ForbiddenError, UnauthorizedError


def make_token_data(
    user_id=None,
    tenant_id=None,
    token_type="access",
    jti="test-jti-123",
) -> TokenData:
    """Helper to create TokenData for tests."""
    return TokenData(
        user_id=user_id or uuid4(),
        tenant_id=tenant_id or uuid4(),
        exp=datetime.now(UTC) + timedelta(hours=1),
        type=token_type,
        jti=jti,
    )


def make_credentials(token="valid-token") -> HTTPAuthorizationCredentials:
    """Helper to create HTTPAuthorizationCredentials."""
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


class TestGetTokenData:
    """Tests for get_token_data dependency."""

    @pytest.mark.asyncio
    async def test_missing_credentials_raises_unauthorized(self):
        """Verify UnauthorizedError raised when credentials are None."""
        mock_db = AsyncMock()

        with pytest.raises(UnauthorizedError) as exc_info:
            await get_token_data(credentials=None, db=mock_db)

        assert exc_info.value.error_code == "missing_token"

    @pytest.mark.asyncio
    async def test_invalid_token_raises_unauthorized(self):
        """Verify UnauthorizedError raised when token cannot be decoded."""
        mock_db = AsyncMock()
        credentials = make_credentials("invalid-token")

        with patch("app.core.auth.dependencies.decode_token") as mock_decode:
            mock_decode.return_value = None

            with pytest.raises(UnauthorizedError) as exc_info:
                await get_token_data(credentials=credentials, db=mock_db)

            assert exc_info.value.error_code == "invalid_token"

    @pytest.mark.asyncio
    async def test_wrong_token_type_raises_unauthorized(self):
        """Verify UnauthorizedError raised for refresh token type."""
        mock_db = AsyncMock()
        credentials = make_credentials("refresh-token")
        token_data = make_token_data(token_type="refresh")

        with patch("app.core.auth.dependencies.decode_token") as mock_decode:
            mock_decode.return_value = token_data

            with pytest.raises(UnauthorizedError) as exc_info:
                await get_token_data(credentials=credentials, db=mock_db)

            assert exc_info.value.error_code == "invalid_token_type"

    @pytest.mark.asyncio
    async def test_revoked_token_raises_unauthorized(self):
        """Verify UnauthorizedError raised when token is revoked."""
        mock_db = AsyncMock()
        credentials = make_credentials("revoked-token")
        token_data = make_token_data(token_type="access", jti="revoked-jti")

        with (
            patch("app.core.auth.dependencies.decode_token") as mock_decode,
            patch("app.modules.users.repos.RevokedTokenRepository") as mock_repo_class,
        ):
            mock_decode.return_value = token_data
            mock_repo = AsyncMock()
            mock_repo.is_revoked.return_value = True
            mock_repo_class.return_value = mock_repo

            with pytest.raises(UnauthorizedError) as exc_info:
                await get_token_data(credentials=credentials, db=mock_db)

            assert exc_info.value.error_code == "token_revoked"

    @pytest.mark.asyncio
    async def test_valid_token_returns_token_data(self):
        """Verify valid token returns TokenData."""
        mock_db = AsyncMock()
        credentials = make_credentials("valid-token")
        expected_token_data = make_token_data(token_type="access", jti="valid-jti")

        with (
            patch("app.core.auth.dependencies.decode_token") as mock_decode,
            patch("app.modules.users.repos.RevokedTokenRepository") as mock_repo_class,
        ):
            mock_decode.return_value = expected_token_data
            mock_repo = AsyncMock()
            mock_repo.is_revoked.return_value = False
            mock_repo_class.return_value = mock_repo

            result = await get_token_data(credentials=credentials, db=mock_db)

            assert result == expected_token_data

    @pytest.mark.asyncio
    async def test_token_without_jti_skips_revocation_check(self):
        """Verify token without jti doesn't check revocation."""
        mock_db = AsyncMock()
        credentials = make_credentials("no-jti-token")
        token_data = make_token_data(token_type="access", jti=None)

        with patch("app.core.auth.dependencies.decode_token") as mock_decode:
            mock_decode.return_value = token_data

            result = await get_token_data(credentials=credentials, db=mock_db)

            assert result == token_data


class TestGetCurrentUser:
    """Tests for get_current_user dependency."""

    @pytest.mark.asyncio
    async def test_valid_user_returned(self):
        """Verify active user is returned successfully."""
        mock_db = AsyncMock()
        user_id = uuid4()
        tenant_id = uuid4()
        token_data = make_token_data(user_id=user_id, tenant_id=tenant_id)

        mock_user = MagicMock()
        mock_user.id = user_id
        mock_user.is_active = True

        with patch("app.modules.users.repos.UserRepository") as mock_repo_class:
            mock_repo = AsyncMock()
            mock_repo.get_by_id.return_value = mock_user
            mock_repo_class.return_value = mock_repo

            result = await get_current_user(token_data=token_data, db=mock_db)

            assert result == mock_user
            mock_repo.get_by_id.assert_awaited_once_with(user_id, tenant_id)

    @pytest.mark.asyncio
    async def test_user_not_found_raises_unauthorized(self):
        """Verify UnauthorizedError raised when user not found."""
        mock_db = AsyncMock()
        token_data = make_token_data()

        with patch("app.modules.users.repos.UserRepository") as mock_repo_class:
            mock_repo = AsyncMock()
            mock_repo.get_by_id.return_value = None
            mock_repo_class.return_value = mock_repo

            with pytest.raises(UnauthorizedError) as exc_info:
                await get_current_user(token_data=token_data, db=mock_db)

            assert exc_info.value.error_code == "user_not_found"

    @pytest.mark.asyncio
    async def test_inactive_user_raises_forbidden(self):
        """Verify ForbiddenError raised when user is inactive."""
        mock_db = AsyncMock()
        token_data = make_token_data()

        mock_user = MagicMock()
        mock_user.is_active = False

        with patch("app.modules.users.repos.UserRepository") as mock_repo_class:
            mock_repo = AsyncMock()
            mock_repo.get_by_id.return_value = mock_user
            mock_repo_class.return_value = mock_repo

            with pytest.raises(ForbiddenError) as exc_info:
                await get_current_user(token_data=token_data, db=mock_db)

            assert exc_info.value.error_code == "user_inactive"


class TestGetCurrentSuperuser:
    """Tests for get_current_superuser dependency."""

    @pytest.mark.asyncio
    async def test_superuser_returned(self):
        """Verify superuser is returned successfully."""
        mock_user = MagicMock()
        mock_user.is_superuser = True

        result = await get_current_superuser(user=mock_user)

        assert result == mock_user

    @pytest.mark.asyncio
    async def test_non_superuser_raises_forbidden(self):
        """Verify ForbiddenError raised for non-superuser."""
        mock_user = MagicMock()
        mock_user.is_superuser = False

        with pytest.raises(ForbiddenError) as exc_info:
            await get_current_superuser(user=mock_user)

        assert exc_info.value.error_code == "not_superuser"


class TestGetTenantId:
    """Tests for get_tenant_id dependency."""

    @pytest.mark.asyncio
    async def test_returns_tenant_id_from_token(self):
        """Verify tenant_id is extracted from token data."""
        tenant_id = uuid4()
        token_data = make_token_data(tenant_id=tenant_id)

        result = await get_tenant_id(token_data=token_data)

        assert result == tenant_id


class TestGetOptionalUser:
    """Tests for get_optional_user dependency."""

    @pytest.mark.asyncio
    async def test_no_credentials_returns_none(self):
        """Verify None returned when no credentials provided."""
        mock_db = AsyncMock()

        result = await get_optional_user(credentials=None, db=mock_db)

        assert result is None

    @pytest.mark.asyncio
    async def test_invalid_token_returns_none(self):
        """Verify None returned when token cannot be decoded."""
        mock_db = AsyncMock()
        credentials = make_credentials("invalid-token")

        with patch("app.core.auth.dependencies.decode_token") as mock_decode:
            mock_decode.return_value = None

            result = await get_optional_user(credentials=credentials, db=mock_db)

            assert result is None

    @pytest.mark.asyncio
    async def test_wrong_token_type_returns_none(self):
        """Verify None returned for refresh token type."""
        mock_db = AsyncMock()
        credentials = make_credentials("refresh-token")
        token_data = make_token_data(token_type="refresh")

        with patch("app.core.auth.dependencies.decode_token") as mock_decode:
            mock_decode.return_value = token_data

            result = await get_optional_user(credentials=credentials, db=mock_db)

            assert result is None

    @pytest.mark.asyncio
    async def test_revoked_token_returns_none(self):
        """Verify None returned when token is revoked."""
        mock_db = AsyncMock()
        credentials = make_credentials("revoked-token")
        token_data = make_token_data(token_type="access", jti="revoked-jti")

        with (
            patch("app.core.auth.dependencies.decode_token") as mock_decode,
            patch("app.modules.users.repos.RevokedTokenRepository") as mock_repo_class,
        ):
            mock_decode.return_value = token_data
            mock_repo = AsyncMock()
            mock_repo.is_revoked.return_value = True
            mock_repo_class.return_value = mock_repo

            result = await get_optional_user(credentials=credentials, db=mock_db)

            assert result is None

    @pytest.mark.asyncio
    async def test_user_not_found_returns_none(self):
        """Verify None returned when user not found."""
        mock_db = AsyncMock()
        credentials = make_credentials("valid-token")
        token_data = make_token_data(token_type="access", jti="valid-jti")

        with (
            patch("app.core.auth.dependencies.decode_token") as mock_decode,
            patch(
                "app.modules.users.repos.RevokedTokenRepository"
            ) as mock_revoked_repo_class,
            patch("app.modules.users.repos.UserRepository") as mock_user_repo_class,
        ):
            mock_decode.return_value = token_data
            mock_revoked_repo = AsyncMock()
            mock_revoked_repo.is_revoked.return_value = False
            mock_revoked_repo_class.return_value = mock_revoked_repo
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_id.return_value = None
            mock_user_repo_class.return_value = mock_user_repo

            result = await get_optional_user(credentials=credentials, db=mock_db)

            assert result is None

    @pytest.mark.asyncio
    async def test_inactive_user_returns_none(self):
        """Verify None returned when user is inactive."""
        mock_db = AsyncMock()
        credentials = make_credentials("valid-token")
        token_data = make_token_data(token_type="access", jti="valid-jti")

        mock_user = MagicMock()
        mock_user.is_active = False

        with (
            patch("app.core.auth.dependencies.decode_token") as mock_decode,
            patch(
                "app.modules.users.repos.RevokedTokenRepository"
            ) as mock_revoked_repo_class,
            patch("app.modules.users.repos.UserRepository") as mock_user_repo_class,
        ):
            mock_decode.return_value = token_data
            mock_revoked_repo = AsyncMock()
            mock_revoked_repo.is_revoked.return_value = False
            mock_revoked_repo_class.return_value = mock_revoked_repo
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_id.return_value = mock_user
            mock_user_repo_class.return_value = mock_user_repo

            result = await get_optional_user(credentials=credentials, db=mock_db)

            assert result is None

    @pytest.mark.asyncio
    async def test_valid_user_returned(self):
        """Verify valid active user is returned."""
        mock_db = AsyncMock()
        credentials = make_credentials("valid-token")
        user_id = uuid4()
        tenant_id = uuid4()
        token_data = make_token_data(
            user_id=user_id, tenant_id=tenant_id, token_type="access", jti="valid-jti"
        )

        mock_user = MagicMock()
        mock_user.id = user_id
        mock_user.is_active = True

        with (
            patch("app.core.auth.dependencies.decode_token") as mock_decode,
            patch(
                "app.modules.users.repos.RevokedTokenRepository"
            ) as mock_revoked_repo_class,
            patch("app.modules.users.repos.UserRepository") as mock_user_repo_class,
        ):
            mock_decode.return_value = token_data
            mock_revoked_repo = AsyncMock()
            mock_revoked_repo.is_revoked.return_value = False
            mock_revoked_repo_class.return_value = mock_revoked_repo
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_id.return_value = mock_user
            mock_user_repo_class.return_value = mock_user_repo

            result = await get_optional_user(credentials=credentials, db=mock_db)

            assert result == mock_user

    @pytest.mark.asyncio
    async def test_token_without_jti_skips_revocation_check(self):
        """Verify token without jti doesn't check revocation."""
        mock_db = AsyncMock()
        credentials = make_credentials("no-jti-token")
        token_data = make_token_data(token_type="access", jti=None)

        mock_user = MagicMock()
        mock_user.is_active = True

        with (
            patch("app.core.auth.dependencies.decode_token") as mock_decode,
            patch("app.modules.users.repos.UserRepository") as mock_user_repo_class,
        ):
            mock_decode.return_value = token_data
            mock_user_repo = AsyncMock()
            mock_user_repo.get_by_id.return_value = mock_user
            mock_user_repo_class.return_value = mock_user_repo

            result = await get_optional_user(credentials=credentials, db=mock_db)

            assert result == mock_user
