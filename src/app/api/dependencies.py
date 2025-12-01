"""Shared API dependencies."""

from collections.abc import AsyncGenerator
from typing import Annotated

from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db


# Type alias for database session dependency
DBSession = Annotated[AsyncSession, Depends(get_db)]


async def get_current_tenant_id() -> AsyncGenerator[str | None, None]:
    """Get current tenant ID from request context.

    This is a placeholder that will be implemented in Phase 2
    with proper authentication middleware.
    """
    # TODO: Extract tenant_id from authenticated user
    yield None


CurrentTenantId = Annotated[str | None, Depends(get_current_tenant_id)]
