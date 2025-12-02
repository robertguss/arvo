"""Shared API dependencies."""

from typing import Annotated

from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db


# Type alias for database session dependency
DBSession = Annotated[AsyncSession, Depends(get_db)]


# Note: Tenant context is now handled by TenantContextMiddleware.
# For authenticated routes, use TenantId from app.core.auth.dependencies
# which extracts tenant_id from the JWT token.
