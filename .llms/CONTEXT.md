# Agency Standard - Project Context

## Overview

A multi-tenant SaaS backend built with FastAPI and PostgreSQL. This is a production-ready Python backend kit for software agencies.

## Technology Stack

| Component | Technology |
|-----------|------------|
| Language | Python 3.12+ |
| Framework | FastAPI 0.111+ |
| ORM | SQLAlchemy 2.0 (async) |
| Database | PostgreSQL 16+ |
| Cache | Redis 7 |
| Background Jobs | ARQ |
| Validation | Pydantic v2 |
| Package Manager | uv |

## Key Patterns

### Multi-Tenancy

Every request has a tenant context. The `TenantMixin` adds a `tenant_id` column to models, and the `TenantSession` wrapper automatically filters queries by tenant.

```python
# All tenant-scoped models use TenantMixin
class Item(Base, UUIDMixin, TimestampMixin, TenantMixin):
    __tablename__ = "items"
    ...
```

Never query without tenant context unless explicitly bypassing for admin operations.

### Service-Repository Pattern

```
Routes → Services → Repositories → Models
```

- **Routes**: HTTP handling, request/response transformation
- **Services**: Business logic, orchestration
- **Repositories**: Data access, query building
- **Models**: Table definitions (pure data)

### Authentication (Phase 2)

JWT tokens with 15-minute expiry. Refresh tokens in HTTP-only cookies.
OAuth2 supported for Google, Microsoft, GitHub.

### Permissions (Phase 2)

RBAC system with roles and permissions. Use `@require_permission("resource", "action")`.

## Project Structure

```
src/app/
├── main.py           # create_app() factory
├── config.py         # pydantic-settings
├── core/
│   └── database/     # Session, base, mixins, tenant
├── modules/
│   └── tenants/      # Multi-tenancy module
└── api/
    ├── router.py     # Health endpoints, module mounting
    └── dependencies.py
```

## Development Commands

```bash
just dev          # Start server with hot-reload
just test         # Run tests
just lint         # Lint + type check
just migrate      # Run migrations
just services     # Start PostgreSQL + Redis
```

## Environment Variables

See `.env.example` for all configuration options.

Key variables:
- `DATABASE_URL` - PostgreSQL connection string
- `REDIS_URL` - Redis connection string
- `SECRET_KEY` - JWT signing key
- `ENVIRONMENT` - development/staging/production

