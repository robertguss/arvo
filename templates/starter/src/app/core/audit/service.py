"""Audit service for logging actions and changes.

Provides both manual logging API and automatic change capture.
"""

from typing import Any
from uuid import UUID

import structlog
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.audit.models import AuditLog


log = structlog.get_logger()


class AuditContext:
    """Context for audit logging within a request.

    Captures request-level information that should be included
    in all audit entries for the current request.
    """

    def __init__(
        self,
        tenant_id: UUID,
        user_id: UUID | None = None,
        ip_address: str | None = None,
        user_agent: str | None = None,
        request_id: str | None = None,
    ) -> None:
        """Initialize audit context.

        Args:
            tenant_id: Current tenant ID
            user_id: Current user ID (if authenticated)
            ip_address: Client IP address
            user_agent: Client user agent
            request_id: Request correlation ID
        """
        self.tenant_id = tenant_id
        self.user_id = user_id
        self.ip_address = ip_address
        self.user_agent = user_agent
        self.request_id = request_id


class AuditService:
    """Service for creating audit log entries.

    Use this service to explicitly log important actions that
    should be tracked for compliance and debugging.
    """

    def __init__(
        self,
        session: AsyncSession,
        context: AuditContext,
    ) -> None:
        """Initialize audit service.

        Args:
            session: Database session
            context: Audit context with request info
        """
        self.session = session
        self.context = context

    async def log(
        self,
        action: str,
        resource_type: str,
        resource_id: str | None = None,
        changes: dict[str, Any] | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> AuditLog:
        """Create an audit log entry.

        Args:
            action: Type of action (e.g., "login", "export", "create")
            resource_type: Type of resource (e.g., "user", "report")
            resource_id: ID of the affected resource
            changes: Dictionary of field changes
            metadata: Additional context data

        Returns:
            Created audit log entry

        Example:
            await audit.log(
                action="export",
                resource_type="report",
                resource_id=str(report.id),
                metadata={"format": "csv", "rows": 1500}
            )
        """
        entry = AuditLog(
            tenant_id=self.context.tenant_id,
            user_id=self.context.user_id,
            action=action,
            resource_type=resource_type,
            resource_id=resource_id,
            ip_address=self.context.ip_address,
            user_agent=self.context.user_agent,
            request_id=self.context.request_id,
            changes=changes,
            metadata_=metadata,
        )

        self.session.add(entry)
        await self.session.flush()

        log.info(
            "audit_log_created",
            action=action,
            resource_type=resource_type,
            resource_id=resource_id,
            user_id=str(self.context.user_id) if self.context.user_id else None,
        )

        return entry

    async def log_login(
        self,
        user_id: UUID,
        success: bool,
        method: str = "password",
        failure_reason: str | None = None,
    ) -> AuditLog:
        """Log a login attempt.

        Args:
            user_id: User attempting to log in
            success: Whether login succeeded
            method: Authentication method (password, oauth, etc.)
            failure_reason: Reason for failure if unsuccessful

        Returns:
            Created audit log entry
        """
        return await self.log(
            action="login_success" if success else "login_failure",
            resource_type="auth",
            resource_id=str(user_id),
            metadata={
                "method": method,
                "failure_reason": failure_reason,
            },
        )

    async def log_logout(self, user_id: UUID) -> AuditLog:
        """Log a logout action.

        Args:
            user_id: User logging out

        Returns:
            Created audit log entry
        """
        return await self.log(
            action="logout",
            resource_type="auth",
            resource_id=str(user_id),
        )

    async def log_permission_denied(
        self,
        resource_type: str,
        resource_id: str | None,
        required_permission: str,
    ) -> AuditLog:
        """Log a permission denied event.

        Args:
            resource_type: Type of resource access was denied for
            resource_id: ID of the resource
            required_permission: Permission that was required

        Returns:
            Created audit log entry
        """
        return await self.log(
            action="permission_denied",
            resource_type=resource_type,
            resource_id=resource_id,
            metadata={"required_permission": required_permission},
        )
