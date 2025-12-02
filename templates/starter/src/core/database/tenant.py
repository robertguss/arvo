"""Tenant-scoped database session.

This module provides a session wrapper that automatically
filters all queries by tenant_id for multi-tenancy support.
"""

from typing import TYPE_CHECKING, Any
from uuid import UUID

from sqlalchemy import Select
from sqlalchemy.ext.asyncio import AsyncSession


if TYPE_CHECKING:
    from sqlalchemy.sql import ColumnElement


class TenantContextRequired(Exception):
    """Raised when tenant context is required but not provided."""

    def __init__(self, message: str = "Tenant context is required for this operation"):
        self.message = message
        super().__init__(self.message)


class TenantSession:
    """Wraps AsyncSession with automatic tenant filtering.

    This class ensures that all database operations are scoped
    to the current tenant, preventing cross-tenant data access.

    Usage:
        tenant_session = TenantSession(session, tenant_id)
        result = await tenant_session.execute(select(User))
    """

    def __init__(self, session: AsyncSession, tenant_id: UUID) -> None:
        self.session = session
        self.tenant_id = tenant_id

    def _apply_tenant_filter(self, statement: Select[Any], model: Any) -> Select[Any]:
        """Apply tenant_id filter to a select statement."""
        if hasattr(model, "tenant_id"):
            tenant_column: ColumnElement[UUID] = model.tenant_id
            return statement.where(tenant_column == self.tenant_id)
        return statement

    async def execute(self, statement: Select[Any]) -> Any:
        """Execute a statement with automatic tenant filtering.

        Note: This is a simplified implementation. In production,
        you would want more sophisticated handling of different
        statement types and JOIN scenarios.
        """
        # Get the primary entity from the statement
        if hasattr(statement, "column_descriptions") and statement.column_descriptions:
            for desc in statement.column_descriptions:
                entity = desc.get("entity")
                if entity is not None:
                    statement = self._apply_tenant_filter(statement, entity)
                    break

        return await self.session.execute(statement)

    async def get(self, entity: type[Any], ident: Any) -> Any | None:
        """Get an entity by ID, scoped to tenant."""
        obj = await self.session.get(entity, ident)
        if (
            obj is not None
            and hasattr(obj, "tenant_id")
            and obj.tenant_id != self.tenant_id
        ):
            return None
        return obj

    def add(self, instance: Any) -> None:
        """Add an instance, automatically setting tenant_id if applicable."""
        if hasattr(instance, "tenant_id") and instance.tenant_id is None:
            instance.tenant_id = self.tenant_id
        self.session.add(instance)

    async def flush(self) -> None:
        """Flush pending changes to the database."""
        await self.session.flush()

    async def commit(self) -> None:
        """Commit the current transaction."""
        await self.session.commit()

    async def rollback(self) -> None:
        """Rollback the current transaction."""
        await self.session.rollback()

    async def refresh(self, instance: Any) -> None:
        """Refresh an instance from the database."""
        await self.session.refresh(instance)
