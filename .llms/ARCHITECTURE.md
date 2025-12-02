# Agency Standard - Architecture

## System Design

### Modular Monolith

The application is a single deployable unit with strict internal boundaries. Modules communicate through well-defined interfaces, not direct imports.

```
┌─────────────────────────────────────────────────────────┐
│                      FastAPI App                        │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   Users     │  │   Tenants   │  │  [Future Module]│  │
│  │   Module    │  │   Module    │  │                 │  │
│  └──────┬──────┘  └──────┬──────┘  └────────┬────────┘  │
│         │                │                  │           │
├─────────┴────────────────┴──────────────────┴───────────┤
│                    Core Services                        │
│  (Auth, Permissions, Events, Jobs, Cache, Logging)      │
├─────────────────────────────────────────────────────────┤
│                    Data Layer                           │
│  (Repositories, Models, Database Sessions)              │
└─────────────────────────────────────────────────────────┘
```

### Layer Responsibilities

| Layer            | Responsibility                                 | Can Import                           |
| ---------------- | ---------------------------------------------- | ------------------------------------ |
| **Routes**       | HTTP handling, request/response transformation | Services, Schemas                    |
| **Schemas**      | Request/response validation, serialization     | Nothing (pure data)                  |
| **Services**     | Business logic, orchestration                  | Repos, Core Services, other Services |
| **Repositories** | Data access, query building                    | Models, Database                     |
| **Models**       | Table definitions, relationships               | Nothing (pure data)                  |
| **Core**         | Cross-cutting concerns                         | Database, Config                     |

### Import Rules (Enforced by Tach)

- Routes **cannot** import Repositories
- Services **cannot** import Routes
- Models import nothing

## Multi-Tenancy Strategy

### Row-Level Isolation

Every tenant's data lives in the same tables but is isolated by `tenant_id`. A middleware extracts tenant context from the authenticated user and injects it into all queries.

### Why Row-Level Over Schema-Level

- Simpler migrations (one schema to manage)
- Lower operational overhead
- Scales to thousands of tenants
- Easier to implement cross-tenant admin features

### Tenant Context Flow

```
Request → Auth Middleware → Tenant Middleware → Route Handler
                                    │
                                    ▼
                         TenantContext injected
                         into request.state
                                    │
                                    ▼
                         Repository uses context
                         to scope all queries
```

### Tenant Isolation Guarantees

| Scenario                     | Behavior                                         |
| ---------------------------- | ------------------------------------------------ |
| Query without tenant context | Raises `TenantContextRequired` exception         |
| Cross-tenant data access     | Impossible via normal repository methods         |
| Admin/superuser access       | Explicit `bypass_tenant=True` parameter required |
| Tenant deletion              | Cascading delete of all tenant data              |

## Database Design

### Base Mixins

```python
class UUIDMixin:
    """UUID primary key"""
    id: Mapped[UUID]

class TimestampMixin:
    """created_at, updated_at"""
    created_at: Mapped[datetime]
    updated_at: Mapped[datetime]

class TenantMixin:
    """tenant_id foreign key"""
    tenant_id: Mapped[UUID]
```

### Session Management

- Async sessions via `asyncpg`
- Connection pooling with pre-ping
- Transaction-per-request pattern

## Error Handling

All errors return RFC 7807 Problem Details format:

```json
{
  "type": "https://api.example.com/errors/validation",
  "title": "Validation Error",
  "status": 422,
  "detail": "The request body contains invalid data",
  "instance": "/api/v1/users",
  "trace_id": "abc123"
}
```
