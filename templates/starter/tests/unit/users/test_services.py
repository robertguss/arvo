"""Unit tests for UserService."""

from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from app.core.errors import ConflictError, NotFoundError
from app.modules.users.models import User
from app.modules.users.schemas import UserCreate, UserCreateOAuth, UserUpdate
from app.modules.users.services import UserService


class TestCreateUser:
    """Tests for UserService.create_user method."""

    @pytest.mark.asyncio
    async def test_create_user_success(self):
        """Verify user is created successfully with valid data."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()
        mock_repo.get_by_email.return_value = None

        created_user = User(
            id=uuid4(),
            email="new@example.com",
            full_name="New User",
            password_hash="hashed",
            tenant_id=tenant_id,
        )
        mock_repo.create.return_value = created_user

        service = UserService(repo=mock_repo)
        data = UserCreate(
            email="new@example.com",
            full_name="New User",
            password="TestPassword123!",
        )

        result = await service.create_user(
            data=data,
            tenant_id=tenant_id,
            password_hash="hashed",
        )

        assert result == created_user
        mock_repo.get_by_email.assert_awaited_once_with("new@example.com", tenant_id)
        mock_repo.create.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_create_user_duplicate_email_raises_conflict(self):
        """Verify ConflictError raised when email already exists."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()
        existing_user = User(
            id=uuid4(),
            email="exists@example.com",
            full_name="Existing",
            password_hash="hash",
            tenant_id=tenant_id,
        )
        mock_repo.get_by_email.return_value = existing_user

        service = UserService(repo=mock_repo)
        data = UserCreate(
            email="exists@example.com",
            full_name="New User",
            password="TestPassword123!",
        )

        with pytest.raises(ConflictError) as exc_info:
            await service.create_user(
                data=data,
                tenant_id=tenant_id,
                password_hash="hashed",
            )

        assert exc_info.value.error_code == "registration_failed"
        mock_repo.create.assert_not_awaited()


class TestCreateOAuthUser:
    """Tests for UserService.create_oauth_user method."""

    @pytest.mark.asyncio
    async def test_create_oauth_user_success(self):
        """Verify OAuth user is created successfully."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()
        mock_repo.get_by_oauth.return_value = None

        created_user = User(
            id=uuid4(),
            email="oauth@example.com",
            full_name="OAuth User",
            oauth_provider="google",
            oauth_id="google123",
            tenant_id=tenant_id,
        )
        mock_repo.create.return_value = created_user

        service = UserService(repo=mock_repo)
        data = UserCreateOAuth(
            email="oauth@example.com",
            full_name="OAuth User",
            oauth_provider="google",
            oauth_id="google123",
        )

        result = await service.create_oauth_user(data=data, tenant_id=tenant_id)

        assert result == created_user
        mock_repo.get_by_oauth.assert_awaited_once_with("google", "google123", tenant_id)
        mock_repo.create.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_create_oauth_user_duplicate_raises_conflict(self):
        """Verify ConflictError raised when OAuth ID already exists."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()
        existing_user = User(
            id=uuid4(),
            email="exists@example.com",
            full_name="Existing",
            oauth_provider="google",
            oauth_id="google123",
            tenant_id=tenant_id,
        )
        mock_repo.get_by_oauth.return_value = existing_user

        service = UserService(repo=mock_repo)
        data = UserCreateOAuth(
            email="new@example.com",
            full_name="New User",
            oauth_provider="google",
            oauth_id="google123",
        )

        with pytest.raises(ConflictError) as exc_info:
            await service.create_oauth_user(data=data, tenant_id=tenant_id)

        assert exc_info.value.error_code == "oauth_exists"
        mock_repo.create.assert_not_awaited()


class TestGetUser:
    """Tests for UserService.get_user method."""

    @pytest.mark.asyncio
    async def test_get_user_success(self):
        """Verify user is returned when found."""
        tenant_id = uuid4()
        user_id = uuid4()
        mock_repo = AsyncMock()

        found_user = User(
            id=user_id,
            email="user@example.com",
            full_name="Found User",
            password_hash="hash",
            tenant_id=tenant_id,
        )
        mock_repo.get_by_id.return_value = found_user

        service = UserService(repo=mock_repo)
        result = await service.get_user(user_id=user_id, tenant_id=tenant_id)

        assert result == found_user
        mock_repo.get_by_id.assert_awaited_once_with(user_id, tenant_id)

    @pytest.mark.asyncio
    async def test_get_user_not_found_raises_error(self):
        """Verify NotFoundError raised when user doesn't exist."""
        tenant_id = uuid4()
        user_id = uuid4()
        mock_repo = AsyncMock()
        mock_repo.get_by_id.return_value = None

        service = UserService(repo=mock_repo)

        with pytest.raises(NotFoundError) as exc_info:
            await service.get_user(user_id=user_id, tenant_id=tenant_id)

        assert exc_info.value.details["resource"] == "user"
        assert exc_info.value.details["resource_id"] == str(user_id)


class TestGetUserByEmail:
    """Tests for UserService.get_user_by_email method."""

    @pytest.mark.asyncio
    async def test_get_user_by_email_found(self):
        """Verify user is returned when found by email."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()

        found_user = User(
            id=uuid4(),
            email="find@example.com",
            full_name="Found User",
            password_hash="hash",
            tenant_id=tenant_id,
        )
        mock_repo.get_by_email.return_value = found_user

        service = UserService(repo=mock_repo)
        result = await service.get_user_by_email(
            email="find@example.com", tenant_id=tenant_id
        )

        assert result == found_user
        mock_repo.get_by_email.assert_awaited_once_with("find@example.com", tenant_id)

    @pytest.mark.asyncio
    async def test_get_user_by_email_not_found_returns_none(self):
        """Verify None is returned when user not found by email."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()
        mock_repo.get_by_email.return_value = None

        service = UserService(repo=mock_repo)
        result = await service.get_user_by_email(
            email="notfound@example.com", tenant_id=tenant_id
        )

        assert result is None


class TestGetOrCreateOAuthUser:
    """Tests for UserService.get_or_create_oauth_user method."""

    @pytest.mark.asyncio
    async def test_returns_existing_user_by_oauth_id(self):
        """Verify existing user returned when found by OAuth ID."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()

        existing_user = User(
            id=uuid4(),
            email="existing@example.com",
            full_name="Existing User",
            oauth_provider="google",
            oauth_id="google123",
            tenant_id=tenant_id,
        )
        mock_repo.get_by_oauth.return_value = existing_user

        service = UserService(repo=mock_repo)
        user, created = await service.get_or_create_oauth_user(
            email="existing@example.com",
            full_name="Existing User",
            oauth_provider="google",
            oauth_id="google123",
            tenant_id=tenant_id,
        )

        assert user == existing_user
        assert created is False
        mock_repo.get_by_email.assert_not_awaited()
        mock_repo.create.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_links_oauth_to_existing_email_user(self):
        """Verify OAuth is linked to existing user found by email."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()
        mock_repo.get_by_oauth.return_value = None

        existing_user = MagicMock(spec=User)
        existing_user.id = uuid4()
        existing_user.email = "existing@example.com"
        existing_user.oauth_provider = None
        existing_user.oauth_id = None
        mock_repo.get_by_email.return_value = existing_user
        mock_repo.update.return_value = existing_user

        service = UserService(repo=mock_repo)
        user, created = await service.get_or_create_oauth_user(
            email="existing@example.com",
            full_name="Existing User",
            oauth_provider="google",
            oauth_id="google123",
            tenant_id=tenant_id,
        )

        assert user == existing_user
        assert created is False
        assert existing_user.oauth_provider == "google"
        assert existing_user.oauth_id == "google123"
        mock_repo.update.assert_awaited_once_with(existing_user)

    @pytest.mark.asyncio
    async def test_creates_new_user_when_not_found(self):
        """Verify new user is created when no existing user found."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()
        mock_repo.get_by_oauth.return_value = None
        mock_repo.get_by_email.return_value = None

        created_user = User(
            id=uuid4(),
            email="new@example.com",
            full_name="New User",
            oauth_provider="google",
            oauth_id="google123",
            tenant_id=tenant_id,
        )
        mock_repo.create.return_value = created_user

        service = UserService(repo=mock_repo)
        user, created = await service.get_or_create_oauth_user(
            email="new@example.com",
            full_name="New User",
            oauth_provider="google",
            oauth_id="google123",
            tenant_id=tenant_id,
        )

        assert user == created_user
        assert created is True
        mock_repo.create.assert_awaited_once()


class TestUpdateUser:
    """Tests for UserService.update_user method."""

    @pytest.mark.asyncio
    async def test_update_user_email_success(self):
        """Verify user email is updated successfully."""
        tenant_id = uuid4()
        user_id = uuid4()
        mock_repo = AsyncMock()

        existing_user = MagicMock(spec=User)
        existing_user.id = user_id
        existing_user.email = "old@example.com"
        existing_user.full_name = "Old Name"
        mock_repo.get_by_id.return_value = existing_user
        mock_repo.get_by_email.return_value = None
        mock_repo.update.return_value = existing_user

        service = UserService(repo=mock_repo)
        data = UserUpdate(email="new@example.com")

        result = await service.update_user(
            user_id=user_id, data=data, tenant_id=tenant_id
        )

        assert existing_user.email == "new@example.com"
        mock_repo.update.assert_awaited_once_with(existing_user)

    @pytest.mark.asyncio
    async def test_update_user_email_conflict_raises_error(self):
        """Verify ConflictError raised when new email already exists."""
        tenant_id = uuid4()
        user_id = uuid4()
        other_user_id = uuid4()
        mock_repo = AsyncMock()

        existing_user = MagicMock(spec=User)
        existing_user.id = user_id
        existing_user.email = "old@example.com"
        mock_repo.get_by_id.return_value = existing_user

        other_user = MagicMock(spec=User)
        other_user.id = other_user_id
        other_user.email = "taken@example.com"
        mock_repo.get_by_email.return_value = other_user

        service = UserService(repo=mock_repo)
        data = UserUpdate(email="taken@example.com")

        with pytest.raises(ConflictError) as exc_info:
            await service.update_user(user_id=user_id, data=data, tenant_id=tenant_id)

        assert exc_info.value.error_code == "update_failed"
        mock_repo.update.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_update_user_name_only(self):
        """Verify user name is updated without email check."""
        tenant_id = uuid4()
        user_id = uuid4()
        mock_repo = AsyncMock()

        existing_user = MagicMock(spec=User)
        existing_user.id = user_id
        existing_user.email = "user@example.com"
        existing_user.full_name = "Old Name"
        mock_repo.get_by_id.return_value = existing_user
        mock_repo.update.return_value = existing_user

        service = UserService(repo=mock_repo)
        data = UserUpdate(full_name="New Name")

        result = await service.update_user(
            user_id=user_id, data=data, tenant_id=tenant_id
        )

        assert existing_user.full_name == "New Name"
        mock_repo.get_by_email.assert_not_awaited()
        mock_repo.update.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_update_user_same_email_no_conflict_check(self):
        """Verify no conflict check when email unchanged."""
        tenant_id = uuid4()
        user_id = uuid4()
        mock_repo = AsyncMock()

        existing_user = MagicMock(spec=User)
        existing_user.id = user_id
        existing_user.email = "same@example.com"
        existing_user.full_name = "Name"
        mock_repo.get_by_id.return_value = existing_user
        mock_repo.update.return_value = existing_user

        service = UserService(repo=mock_repo)
        data = UserUpdate(email="same@example.com", full_name="Updated Name")

        await service.update_user(user_id=user_id, data=data, tenant_id=tenant_id)

        mock_repo.get_by_email.assert_not_awaited()
        mock_repo.update.assert_awaited_once()


class TestListUsers:
    """Tests for UserService.list_users method."""

    @pytest.mark.asyncio
    async def test_list_users_returns_paginated_results(self):
        """Verify list_users returns users and total count."""
        tenant_id = uuid4()
        mock_repo = AsyncMock()

        users = [
            User(
                id=uuid4(),
                email=f"user{i}@example.com",
                full_name=f"User {i}",
                password_hash="hash",
                tenant_id=tenant_id,
            )
            for i in range(3)
        ]
        mock_repo.list_by_tenant.return_value = (users, 10)

        service = UserService(repo=mock_repo)
        result_users, total = await service.list_users(
            tenant_id=tenant_id, page=2, page_size=3
        )

        assert result_users == users
        assert total == 10
        mock_repo.list_by_tenant.assert_awaited_once_with(tenant_id, 2, 3)


class TestDeactivateUser:
    """Tests for UserService.deactivate_user method."""

    @pytest.mark.asyncio
    async def test_deactivate_user_sets_inactive(self):
        """Verify deactivate_user sets is_active to False."""
        tenant_id = uuid4()
        user_id = uuid4()
        mock_repo = AsyncMock()

        user = MagicMock(spec=User)
        user.id = user_id
        user.is_active = True
        mock_repo.get_by_id.return_value = user
        mock_repo.update.return_value = user

        service = UserService(repo=mock_repo)
        result = await service.deactivate_user(user_id=user_id, tenant_id=tenant_id)

        assert user.is_active is False
        mock_repo.update.assert_awaited_once_with(user)


class TestActivateUser:
    """Tests for UserService.activate_user method."""

    @pytest.mark.asyncio
    async def test_activate_user_sets_active(self):
        """Verify activate_user sets is_active to True."""
        tenant_id = uuid4()
        user_id = uuid4()
        mock_repo = AsyncMock()

        user = MagicMock(spec=User)
        user.id = user_id
        user.is_active = False
        mock_repo.get_by_id.return_value = user
        mock_repo.update.return_value = user

        service = UserService(repo=mock_repo)
        result = await service.activate_user(user_id=user_id, tenant_id=tenant_id)

        assert user.is_active is True
        mock_repo.update.assert_awaited_once_with(user)
