"""Core services and cross-cutting concerns.

This module intentionally does not re-export symbols from submodules
to avoid circular imports. Import directly from submodules when needed:

- app.core.database: Base, get_db, TenantMixin, etc.
- app.core.errors: AppException, NotFoundError, etc.
- app.core.auth: auth dependencies and utilities
- app.core.cache: Redis caching utilities
- app.core.jobs: Background job utilities
- app.core.audit: Audit logging
"""
