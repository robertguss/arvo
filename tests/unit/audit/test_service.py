"""Tests for audit logging service."""

from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from app.core.audit.models import AuditLog
from app.core.audit.service import AuditContext, AuditService


class TestAuditContext:
    """Tests for AuditContext."""

    def test_create_context(self):
        """Test creating an audit context."""
        tenant_id = uuid4()
        user_id = uuid4()

        context = AuditContext(
            tenant_id=tenant_id,
            user_id=user_id,
            ip_address="192.168.1.1",
            user_agent="Mozilla/5.0",
            request_id="req-123",
        )

        assert context.tenant_id == tenant_id
        assert context.user_id == user_id
        assert context.ip_address == "192.168.1.1"
        assert context.user_agent == "Mozilla/5.0"
        assert context.request_id == "req-123"

    def test_create_context_minimal(self):
        """Test creating a minimal audit context."""
        tenant_id = uuid4()

        context = AuditContext(tenant_id=tenant_id)

        assert context.tenant_id == tenant_id
        assert context.user_id is None
        assert context.ip_address is None


class TestAuditService:
    """Tests for AuditService."""

    @pytest.fixture
    def mock_session(self):
        """Create a mock database session."""
        session = AsyncMock()
        session.add = MagicMock()
        session.flush = AsyncMock()
        return session

    @pytest.fixture
    def audit_context(self):
        """Create an audit context for testing."""
        return AuditContext(
            tenant_id=uuid4(),
            user_id=uuid4(),
            ip_address="10.0.0.1",
            user_agent="Test Agent",
            request_id="test-req-123",
        )

    @pytest.mark.asyncio
    async def test_log_basic(self, mock_session, audit_context):
        """Test creating a basic audit log entry."""
        service = AuditService(session=mock_session, context=audit_context)

        await service.log(
            action="create",
            resource_type="user",
            resource_id="user-123",
        )

        mock_session.add.assert_called_once()
        mock_session.flush.assert_called_once()

        # Check the entry was created with correct values
        added_entry = mock_session.add.call_args[0][0]
        assert isinstance(added_entry, AuditLog)
        assert added_entry.action == "create"
        assert added_entry.resource_type == "user"
        assert added_entry.resource_id == "user-123"
        assert added_entry.tenant_id == audit_context.tenant_id
        assert added_entry.user_id == audit_context.user_id

    @pytest.mark.asyncio
    async def test_log_with_changes(self, mock_session, audit_context):
        """Test logging with field changes."""
        service = AuditService(session=mock_session, context=audit_context)

        changes = {
            "email": {"old": "old@example.com", "new": "new@example.com"},
            "name": {"old": "Old Name", "new": "New Name"},
        }

        await service.log(
            action="update",
            resource_type="user",
            resource_id="user-123",
            changes=changes,
        )

        added_entry = mock_session.add.call_args[0][0]
        assert added_entry.changes == changes

    @pytest.mark.asyncio
    async def test_log_with_metadata(self, mock_session, audit_context):
        """Test logging with metadata."""
        service = AuditService(session=mock_session, context=audit_context)

        metadata = {"format": "csv", "rows": 1500}

        await service.log(
            action="export",
            resource_type="report",
            resource_id="report-456",
            metadata=metadata,
        )

        added_entry = mock_session.add.call_args[0][0]
        assert added_entry.metadata_ == metadata

    @pytest.mark.asyncio
    async def test_log_login_success(self, mock_session, audit_context):
        """Test logging successful login."""
        service = AuditService(session=mock_session, context=audit_context)
        user_id = uuid4()

        await service.log_login(user_id=user_id, success=True, method="password")

        added_entry = mock_session.add.call_args[0][0]
        assert added_entry.action == "login_success"
        assert added_entry.resource_type == "auth"
        assert added_entry.resource_id == str(user_id)
        assert added_entry.metadata_["method"] == "password"

    @pytest.mark.asyncio
    async def test_log_login_failure(self, mock_session, audit_context):
        """Test logging failed login."""
        service = AuditService(session=mock_session, context=audit_context)
        user_id = uuid4()

        await service.log_login(
            user_id=user_id,
            success=False,
            method="password",
            failure_reason="invalid_password",
        )

        added_entry = mock_session.add.call_args[0][0]
        assert added_entry.action == "login_failure"
        assert added_entry.metadata_["failure_reason"] == "invalid_password"

    @pytest.mark.asyncio
    async def test_log_logout(self, mock_session, audit_context):
        """Test logging logout."""
        service = AuditService(session=mock_session, context=audit_context)
        user_id = uuid4()

        await service.log_logout(user_id=user_id)

        added_entry = mock_session.add.call_args[0][0]
        assert added_entry.action == "logout"
        assert added_entry.resource_id == str(user_id)

    @pytest.mark.asyncio
    async def test_log_permission_denied(self, mock_session, audit_context):
        """Test logging permission denied."""
        service = AuditService(session=mock_session, context=audit_context)

        await service.log_permission_denied(
            resource_type="project",
            resource_id="proj-123",
            required_permission="project:delete",
        )

        added_entry = mock_session.add.call_args[0][0]
        assert added_entry.action == "permission_denied"
        assert added_entry.resource_type == "project"
        assert added_entry.metadata_["required_permission"] == "project:delete"

