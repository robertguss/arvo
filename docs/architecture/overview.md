# Architecture Overview

The Agency Standard follows a **Modular Monolith** architecture pattern. It's a single deployable unit with strict internal boundaries, designed to be simple to understand, deploy, and scale.

## Why Modular Monolith?

| Aspect | Microservices | Modular Monolith |
|--------|--------------|------------------|
| **Deployment** | Complex orchestration | Single container |
| **Development** | Team coordination overhead | Fast iteration |
| **Debugging** | Distributed tracing required | Stack traces work |
| **Scaling** | Per-service scaling | Horizontal scaling |
| **Refactoring** | Contract negotiations | IDE refactoring |

A modular monolith gives you **microservice-like boundaries** with **monolith simplicity**. You can always extract modules to services later if needed.

## System Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      FastAPI App                             │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Users     │  │   Tenants   │  │  [Your Modules]     │  │
│  │   Module    │  │   Module    │  │                     │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         │                │                    │             │
├─────────┴────────────────┴────────────────────┴─────────────┤
│                    Core Services                             │
│  (Auth, Permissions, Jobs, Cache, Rate Limit, Audit)         │
├─────────────────────────────────────────────────────────────┤
│                    Data Layer                                │
│  (AsyncSession, Repositories, SQLAlchemy Models)             │
├─────────────────────────────────────────────────────────────┤
│                    Infrastructure                            │
│  (PostgreSQL, Redis, OpenTelemetry)                          │
└─────────────────────────────────────────────────────────────┘
```

## Layer Responsibilities

The application uses strict layering. Each layer has clear responsibilities and allowed dependencies.

```
Routes → Services → Repositories → Models
```

### Routes (HTTP Layer)

**Location:** `src/app/modules/{module}/routes.py`

**Responsibility:**

- HTTP request/response handling
- Input validation (via Pydantic schemas)
- Authentication/authorization checks
- Calling services

**Can Import:** Services, Schemas, Auth dependencies

```python
@router.post("/items", response_model=ItemResponse)
async def create_item(
    data: ItemCreate,
    service: Annotated[ItemService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> ItemResponse:
    item = await service.create(data, current_user.tenant_id)
    return ItemResponse.model_validate(item)
```

### Services (Business Logic)

**Location:** `src/app/modules/{module}/services.py`

**Responsibility:**

- Business logic and rules
- Orchestrating repository calls
- Cross-cutting concerns (events, audit logging)

**Can Import:** Repositories, Core Services, other Services

```python
class ItemService:
    def __init__(self, repo: Annotated[ItemRepository, Depends()]):
        self.repo = repo

    async def create(self, data: ItemCreate, tenant_id: UUID) -> Item:
        # Business logic here
        return await self.repo.create(Item(tenant_id=tenant_id, **data.model_dump()))
```

### Repositories (Data Access)

**Location:** `src/app/modules/{module}/repos.py`

**Responsibility:**

- Database queries
- Data persistence
- Query optimization

**Can Import:** Models, Database utilities

```python
class ItemRepository:
    def __init__(self, session: Annotated[AsyncSession, Depends(get_db)]):
        self.session = session

    async def create(self, item: Item) -> Item:
        self.session.add(item)
        await self.session.flush()
        return item
```

### Models (Data Definitions)

**Location:** `src/app/modules/{module}/models.py`

**Responsibility:**

- SQLAlchemy table definitions
- Relationships
- Database constraints

**Can Import:** Nothing (pure data definitions)

```python
class Item(Base, UUIDMixin, TimestampMixin, TenantMixin):
    __tablename__ = "items"
    name: Mapped[str] = mapped_column(String(255))
```

### Schemas (Validation)

**Location:** `src/app/modules/{module}/schemas.py`

**Responsibility:**

- Request/response validation
- Serialization
- API contracts

**Can Import:** Nothing (pure data definitions)

```python
class ItemCreate(BaseModel):
    name: str

class ItemResponse(BaseModel):
    id: UUID
    name: str
    model_config = ConfigDict(from_attributes=True)
```

## Architecture Enforcement

Import rules are enforced by [Tach](https://github.com/gauge-sh/tach) at CI time:

- ❌ Routes cannot import Repositories
- ❌ Services cannot import Routes
- ❌ Models cannot import anything from app

Violations fail the CI build. Run `just archcheck` locally to verify.

```toml
# tach.toml
[[modules]]
path = "app.modules.*.routes"
depends_on = ["app.modules.*.services", "app.modules.*.schemas"]

[[modules]]
path = "app.modules.*.services"
depends_on = ["app.modules.*.repos", "app.core"]
```

## Core Services

The `core/` directory contains cross-cutting concerns used by all modules:

| Service | Purpose |
|---------|---------|
| `core/auth/` | JWT authentication, OAuth2, tenant context |
| `core/permissions/` | RBAC permission checking |
| `core/database/` | Async sessions, base models, mixins |
| `core/cache/` | Redis caching with decorators |
| `core/jobs/` | ARQ background job processing |
| `core/rate_limit/` | Sliding window rate limiting |
| `core/audit/` | Audit log tracking |
| `core/errors/` | RFC 7807 error responses |
| `core/logging/` | Structured logging middleware |
| `core/observability/` | OpenTelemetry tracing |

## Directory Structure

```
src/app/
├── main.py              # Application factory
├── config.py            # Pydantic settings
├── core/                # Cross-cutting concerns
│   ├── auth/
│   ├── cache/
│   ├── database/
│   ├── errors/
│   ├── jobs/
│   ├── logging/
│   ├── observability/
│   ├── permissions/
│   └── rate_limit/
├── modules/             # Feature modules
│   ├── tenants/
│   └── users/
└── api/                 # Router and dependencies
    ├── router.py
    └── dependencies.py
```

## Request Flow

Here's how a typical request flows through the system:

```
1. HTTP Request
       ↓
2. FastAPI Router
       ↓
3. Middleware Chain
   - RequestIdMiddleware (adds trace ID)
   - TenantContextMiddleware (extracts tenant)
   - RequestLoggingMiddleware (logs request)
       ↓
4. Route Handler
   - Validates request (Pydantic)
   - Checks authentication
   - Checks permissions
       ↓
5. Service Layer
   - Business logic
   - Calls repositories
       ↓
6. Repository Layer
   - Database queries
   - Uses tenant-scoped session
       ↓
7. Response
   - Serialized via Pydantic
   - RFC 7807 on errors
```

## Next Steps

- [Multi-Tenancy](multi-tenancy.md) - How tenant isolation works
- [Modules](modules.md) - Creating new feature modules
- [Authentication](../api/authentication.md) - Auth flow details

