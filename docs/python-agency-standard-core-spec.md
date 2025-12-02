# The Agency Standard Python Kit — Core Specification

**Version:** 4.0.0 (Core Complete)  
**Status:** Ready for Build  
**Scope:** Core Chassis Only — No Cartridges

---

## 1. Executive Summary

The Agency Standard is a production-ready Python backend kit for software agencies. It provides a complete foundation for building SaaS applications with multi-tenancy, strict typing, and AI-assisted development patterns baked in from day one.

**What This Is:**

- A complete, deployable backend chassis
- Multi-tenant by default
- Strict guardrails for AI-generated code
- Modern "Rust-era" Python tooling

**What This Is Not:**

- A "kitchen sink" boilerplate with half-baked features
- A microservices framework
- A low-code platform

**Value Proposition:**  
Save 20-30 hours of project setup and architectural decisions. Ship your first authenticated, multi-tenant endpoint in under an hour.

---

## 2. Core Principles

### 2.1 Principle of Completeness

Every feature in the core is production-ready. No TODOs, no "left as exercise for the reader." If it ships, it works.

### 2.2 Principle of Isolation

The core is self-contained. Cartridges (future add-ons) are strictly additive. You can run a complete application on the core alone.

### 2.3 Principle of Explicitness

No magic. Auto-discovery is documented. Configuration is centralized. An engineer reading the code for the first time can trace any request from entry to database.

### 2.4 Principle of AI Legibility

The codebase is structured for LLM comprehension: consistent patterns, strict typing, and explicit context maps.

---

## 3. Technology Stack

| Layer               | Choice         | Rationale                                                    |
| ------------------- | -------------- | ------------------------------------------------------------ |
| **Language**        | Python 3.12+   | Exception groups, improved error messages, performance gains |
| **Package Manager** | uv             | 10-100x faster resolution, deterministic lockfile            |
| **Framework**       | FastAPI 0.111+ | Async-native, Pydantic v2 integration, OpenAPI generation    |
| **ORM**             | SQLAlchemy 2.0 | Async support, type-safe queries, mature ecosystem           |
| **Database**        | PostgreSQL 16+ | Row-level security, JSONB, pgvector-ready                    |
| **Migrations**      | Alembic        | Programmatic control, branch support                         |
| **Validation**      | Pydantic v2    | 5-50x faster than v1, strict mode                            |
| **Background Jobs** | ARQ            | Redis-based, async-native, simple                            |
| **Caching**         | Redis          | Industry standard, ARQ compatibility                         |
| **Linting**         | Ruff           | Fast, replaces flake8/isort/black                            |
| **Type Checking**   | Mypy (strict)  | Catch errors before runtime                                  |
| **Arch Linting**    | Tach           | Enforce module boundaries                                    |
| **Task Runner**     | Just           | Cross-platform, readable syntax                              |
| **Scaffolding**     | Copier         | Template updates, conditional generation                     |
| **Containers**      | Docker         | Multi-stage builds, uv layer caching                         |
| **Reverse Proxy**   | Caddy          | Automatic HTTPS, simple config                               |
| **Observability**   | OpenTelemetry  | Vendor-neutral, comprehensive                                |
| **Testing**         | Pytest         | Async fixtures, excellent plugin ecosystem                   |

---

## 4. Architecture

### 4.1 Pattern: Modular Monolith

The application is a single deployable unit with strict internal boundaries. Modules communicate through well-defined interfaces, not direct imports.

```text
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

### 4.2 Layer Responsibilities

| Layer            | Responsibility                                 | Can Import                           |
| ---------------- | ---------------------------------------------- | ------------------------------------ |
| **Routes**       | HTTP handling, request/response transformation | Services, Schemas                    |
| **Schemas**      | Request/response validation, serialization     | Nothing (pure data)                  |
| **Services**     | Business logic, orchestration                  | Repos, Core Services, other Services |
| **Repositories** | Data access, query building                    | Models, Database                     |
| **Models**       | Table definitions, relationships               | Nothing (pure data)                  |
| **Core**         | Cross-cutting concerns                         | Database, Config                     |

**Enforced by Tach:** Routes cannot import Repositories. Services cannot import Routes. Violations fail CI.

### 4.3 Directory Structure

```text
/
├── .github/
│   └── workflows/
│       ├── ci.yml                 # Lint, type-check, test, build
│       └── deploy.yml             # Production deployment
│
├── .llms/                         # AI Context Layer
│   ├── CONTEXT.md                 # Project overview for AI agents
│   ├── ARCHITECTURE.md            # System design decisions
│   ├── PATTERNS.md                # Code patterns and conventions
│   ├── schema.sql                 # Auto-generated DB schema dump
│   └── openapi.yaml               # Auto-generated API spec
│
├── deploy/
│   ├── Dockerfile                 # Multi-stage, uv-optimized
│   ├── Dockerfile.dev             # Development with hot-reload
│   ├── docker-compose.yml         # Local development stack
│   ├── docker-compose.prod.yml    # Production stack
│   └── Caddyfile                  # Reverse proxy config
│
├── docs/                          # MkDocs documentation site
│   ├── mkdocs.yml
│   └── docs/
│       ├── index.md
│       ├── getting-started.md
│       ├── architecture/
│       ├── api/
│       └── deployment/
│
├── scripts/
│   ├── seed.py                    # Demo data generation
│   ├── update_context.py          # Regenerate .llms/ files
│   └── check_migrations.py        # CI migration verification
│
├── tests/
│   ├── conftest.py                # Shared fixtures
│   ├── factories/                 # Polyfactory model factories
│   │   ├── __init__.py
│   │   ├── user.py
│   │   └── tenant.py
│   ├── unit/
│   │   ├── services/
│   │   └── repos/
│   ├── integration/
│   │   ├── api/
│   │   └── jobs/
│   └── e2e/
│       └── flows/
│
├── src/
│   └── app/
│       ├── __init__.py
│       ├── main.py                # Application factory
│       ├── config.py              # Settings via pydantic-settings
│       │
│       ├── core/                  # Cross-cutting concerns
│       │   ├── __init__.py
│       │   ├── auth/
│       │   │   ├── __init__.py
│       │   │   ├── backend.py     # JWT + Session handling
│       │   │   ├── dependencies.py # FastAPI dependencies
│       │   │   ├── middleware.py  # Tenant context injection
│       │   │   └── oauth.py       # OAuth2 providers
│       │   ├── permissions/
│       │   │   ├── __init__.py
│       │   │   ├── models.py      # Role, Permission tables
│       │   │   ├── checker.py     # Permission evaluation
│       │   │   └── decorators.py  # @require_permission
│       │   ├── database/
│       │   │   ├── __init__.py
│       │   │   ├── session.py     # Async session factory
│       │   │   ├── base.py        # Declarative base, mixins
│       │   │   └── tenant.py      # Tenant-scoped session
│       │   ├── cache/
│       │   │   ├── __init__.py
│       │   │   ├── backend.py     # Redis client
│       │   │   └── decorators.py  # @cached, @invalidate
│       │   ├── events/
│       │   │   ├── __init__.py
│       │   │   ├── bus.py         # In-process event bus
│       │   │   └── handlers.py    # Event handler registry
│       │   ├── jobs/
│       │   │   ├── __init__.py
│       │   │   ├── worker.py      # ARQ worker config
│       │   │   ├── registry.py    # Job registration
│       │   │   └── tasks/         # Shared background tasks
│       │   ├── logging/
│       │   │   ├── __init__.py
│       │   │   ├── config.py      # Structlog setup
│       │   │   └── middleware.py  # Request logging
│       │   ├── observability/
│       │   │   ├── __init__.py
│       │   │   ├── tracing.py     # OpenTelemetry setup
│       │   │   ├── metrics.py     # Prometheus metrics
│       │   │   └── health.py      # Health/readiness probes
│       │   ├── errors/
│       │   │   ├── __init__.py
│       │   │   ├── exceptions.py  # Domain exceptions
│       │   │   └── handlers.py    # RFC 7807 error responses
│       │   ├── rate_limit/
│       │   │   ├── __init__.py
│       │   │   ├── backend.py     # Redis sliding window
│       │   │   └── middleware.py  # Rate limit enforcement
│       │   └── audit/
│       │       ├── __init__.py
│       │       ├── models.py      # AuditLog table
│       │       ├── middleware.py  # Auto-capture changes
│       │       └── service.py     # Manual audit entries
│       │
│       ├── modules/               # Feature modules
│       │   ├── __init__.py        # Module auto-discovery
│       │   │
│       │   ├── tenants/           # Multi-tenancy module
│       │   │   ├── __init__.py
│       │   │   ├── routes.py
│       │   │   ├── schemas.py
│       │   │   ├── services.py
│       │   │   ├── repos.py
│       │   │   ├── models.py
│       │   │   └── migrations/
│       │   │       └── versions/
│       │   │
│       │   └── users/             # User management module
│       │       ├── __init__.py
│       │       ├── routes.py
│       │       ├── schemas.py
│       │       ├── services.py
│       │       ├── repos.py
│       │       ├── models.py
│       │       └── migrations/
│       │           └── versions/
│       │
│       └── api/
│           ├── __init__.py
│           ├── router.py          # Root router, module mounting
│           ├── dependencies.py    # Shared API dependencies
│           └── versioning.py      # API version handling
│
├── alembic.ini                    # Alembic configuration
├── copier.yml                     # Scaffolding configuration
├── justfile                       # Task runner commands
├── pyproject.toml                 # Project metadata, dependencies
├── tach.toml                      # Architecture boundary rules
├── ruff.toml                      # Linter configuration
├── mypy.ini                       # Type checker configuration
├── .cursorrules                   # AI coding assistant rules
├── .env.example                   # Environment template
└── README.md
```

---

## 5. Multi-Tenancy (First-Class)

### 5.1 Strategy: Row-Level with Tenant Context

Every tenant's data lives in the same tables but is isolated by `tenant_id`. A middleware extracts tenant context from the authenticated user and injects it into all queries.

**Why Row-Level Over Schema-Level:**

- Simpler migrations (one schema to manage)
- Lower operational overhead
- Scales to thousands of tenants
- Easier to implement cross-tenant admin features

### 5.2 Tenant Context Flow

```text
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

### 5.3 Implementation Details

**Tenant Mixin (applied to all tenant-scoped models):**

```python
class TenantMixin:
    tenant_id: Mapped[UUID] = mapped_column(
        ForeignKey("tenants.id", ondelete="CASCADE"),
        index=True,
        nullable=False,
    )
```

**Tenant-Scoped Session:**

```python
class TenantSession:
    """Wraps async session with automatic tenant filtering."""

    def __init__(self, session: AsyncSession, tenant_id: UUID):
        self.session = session
        self.tenant_id = tenant_id

    async def execute(self, statement: Select) -> Result:
        # Automatically inject tenant_id filter
        if hasattr(statement, 'whereclause'):
            statement = statement.where(
                statement.column_descriptions[0]['entity'].tenant_id == self.tenant_id
            )
        return await self.session.execute(statement)
```

**Middleware:**

```python
@app.middleware("http")
async def tenant_context_middleware(request: Request, call_next):
    if request.state.user:
        request.state.tenant_id = request.state.user.tenant_id
        request.state.tenant_session = TenantSession(
            request.state.db,
            request.state.tenant_id
        )
    return await call_next(request)
```

### 5.4 Tenant Isolation Guarantees

| Scenario                     | Behavior                                         |
| ---------------------------- | ------------------------------------------------ |
| Query without tenant context | Raises `TenantContextRequired` exception         |
| Cross-tenant data access     | Impossible via normal repository methods         |
| Admin/superuser access       | Explicit `bypass_tenant=True` parameter required |
| Tenant deletion              | Cascading delete of all tenant data              |

---

## 6. Authentication & Authorization

### 6.1 Authentication Flow

**Supported Methods:**

1. **JWT Bearer Tokens** — Primary API authentication
2. **HTTP-Only Cookies** — Browser-based sessions
3. **OAuth2** — Google, Microsoft, GitHub (extensible)

**Token Strategy:**

- Access Token: 15-minute expiry, stored in memory/header
- Refresh Token: 7-day expiry, HTTP-only cookie, rotated on use
- Token rotation prevents replay attacks

### 6.2 OAuth2 Implementation

```python
# Configured via environment
OAUTH_PROVIDERS = {
    "google": {
        "client_id": env.GOOGLE_CLIENT_ID,
        "client_secret": env.GOOGLE_CLIENT_SECRET,
        "authorize_url": "https://accounts.google.com/o/oauth2/v2/auth",
        "token_url": "https://oauth2.googleapis.com/token",
        "userinfo_url": "https://www.googleapis.com/oauth2/v2/userinfo",
        "scopes": ["openid", "email", "profile"],
    },
    # Microsoft, GitHub configured similarly
}
```

**Flow:**

1. Client redirects to `/auth/oauth/{provider}/authorize`
2. User authenticates with provider
3. Callback at `/auth/oauth/{provider}/callback`
4. System creates/links user account
5. JWT tokens issued

### 6.3 Permission System (RBAC)

**Models:**

```python
class Role(Base):
    __tablename__ = "roles"

    id: Mapped[UUID]
    tenant_id: Mapped[UUID]  # Roles are tenant-scoped
    name: Mapped[str]        # e.g., "admin", "member", "viewer"
    permissions: Mapped[list["Permission"]] = relationship()

class Permission(Base):
    __tablename__ = "permissions"

    id: Mapped[UUID]
    resource: Mapped[str]    # e.g., "users", "projects"
    action: Mapped[str]      # e.g., "read", "write", "delete"

class UserRole(Base):
    __tablename__ = "user_roles"

    user_id: Mapped[UUID]
    role_id: Mapped[UUID]
```

**Usage in Routes:**

```python
@router.delete("/users/{user_id}")
@require_permission("users", "delete")
async def delete_user(
    user_id: UUID,
    current_user: Annotated[User, Depends(get_current_user)],
    service: Annotated[UserService, Depends()],
):
    await service.delete(user_id)
    return {"status": "deleted"}
```

**Permission Checker:**

```python
class PermissionChecker:
    async def has_permission(
        self,
        user: User,
        resource: str,
        action: str
    ) -> bool:
        # Check user's roles for matching permission
        for role in user.roles:
            for permission in role.permissions:
                if permission.resource == resource and permission.action == action:
                    return True
        return False
```

---

## 7. API Design Standards

### 7.1 Route Requirements (Enforced)

The `AgencyRouter` class extends FastAPI's router to enforce standards at startup:

```python
class AgencyRouter(APIRouter):
    def add_api_route(self, path: str, endpoint: Callable, **kwargs):
        # Enforce response_model
        if "response_model" not in kwargs:
            raise RouterConfigError(
                f"Endpoint {endpoint.__name__} missing response_model"
            )

        # Enforce summary for OpenAPI
        if "summary" not in kwargs:
            raise RouterConfigError(
                f"Endpoint {endpoint.__name__} missing summary"
            )

        # Enforce tags
        if "tags" not in kwargs:
            raise RouterConfigError(
                f"Endpoint {endpoint.__name__} missing tags"
            )

        super().add_api_route(path, endpoint, **kwargs)
```

### 7.2 Error Response Format (RFC 7807)

All errors return a consistent structure:

```json
{
  "type": "https://api.example.com/errors/validation",
  "title": "Validation Error",
  "status": 422,
  "detail": "The request body contains invalid data",
  "instance": "/api/v1/users",
  "errors": [
    {
      "field": "email",
      "message": "Invalid email format"
    }
  ],
  "trace_id": "abc123"
}
```

**Implementation:**

```python
class ProblemDetail(BaseModel):
    type: str
    title: str
    status: int
    detail: str
    instance: str | None = None
    errors: list[FieldError] | None = None
    trace_id: str | None = None

@app.exception_handler(RequestValidationError)
async def validation_error_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=422,
        content=ProblemDetail(
            type="https://api.example.com/errors/validation",
            title="Validation Error",
            status=422,
            detail="Request validation failed",
            instance=str(request.url.path),
            errors=[FieldError(field=e["loc"], message=e["msg"]) for e in exc.errors()],
            trace_id=get_trace_id(),
        ).model_dump(),
    )
```

### 7.3 API Versioning

**Strategy:** URL Path Versioning (`/api/v1/`, `/api/v2/`)

```python
# src/app/api/router.py
from app.api.v1 import router as v1_router
from app.api.v2 import router as v2_router  # When needed

api_router = APIRouter()
api_router.include_router(v1_router, prefix="/v1")
# api_router.include_router(v2_router, prefix="/v2")
```

**Deprecation Headers:**

```python
@router.get("/users", deprecated=True)
async def list_users_v1():
    """Deprecated: Use /api/v2/users instead."""
    response.headers["Deprecation"] = "true"
    response.headers["Sunset"] = "2025-12-31"
    response.headers["Link"] = '</api/v2/users>; rel="successor-version"'
```

### 7.4 Pagination

**Standard Response:**

```python
class PaginatedResponse(BaseModel, Generic[T]):
    items: list[T]
    total: int
    page: int
    page_size: int
    pages: int

    @computed_field
    @property
    def has_next(self) -> bool:
        return self.page < self.pages

    @computed_field
    @property
    def has_prev(self) -> bool:
        return self.page > 1
```

**Usage:**

```python
@router.get("/users", response_model=PaginatedResponse[UserResponse])
async def list_users(
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
):
    ...
```

---

## 8. Rate Limiting

### 8.1 Strategy: Redis Sliding Window

More accurate than fixed windows, prevents burst abuse at window boundaries.

### 8.2 Configuration

```python
# Per-route configuration via decorator
@router.get("/ai/generate")
@rate_limit(requests=10, window=60)  # 10 requests per minute
async def generate():
    ...

# Global defaults in config
class RateLimitSettings(BaseSettings):
    default_requests: int = 100
    default_window: int = 60  # seconds
    redis_url: str

    # Tier-based limits
    tier_limits: dict[str, tuple[int, int]] = {
        "free": (100, 60),
        "pro": (1000, 60),
        "enterprise": (10000, 60),
    }
```

### 8.3 Response Headers

```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 95
X-RateLimit-Reset: 1699999999
Retry-After: 30  # Only on 429
```

### 8.4 Implementation

```python
class SlidingWindowRateLimiter:
    def __init__(self, redis: Redis):
        self.redis = redis

    async def is_allowed(
        self,
        key: str,
        limit: int,
        window: int
    ) -> tuple[bool, int, int]:
        """Returns (allowed, remaining, reset_time)."""
        now = time.time()
        window_start = now - window

        async with self.redis.pipeline() as pipe:
            # Remove old entries
            pipe.zremrangebyscore(key, 0, window_start)
            # Add current request
            pipe.zadd(key, {str(now): now})
            # Count requests in window
            pipe.zcard(key)
            # Set expiry
            pipe.expire(key, window)

            results = await pipe.execute()
            count = results[2]

        remaining = max(0, limit - count)
        reset_time = int(now + window)

        return count <= limit, remaining, reset_time
```

---

## 9. Caching

### 9.1 Strategy: Redis with Decorator Pattern

### 9.2 Cache Decorator

```python
@cached(ttl=300, key_builder=lambda user_id: f"user:{user_id}")
async def get_user(user_id: UUID) -> User:
    return await repo.get(user_id)

@invalidate(pattern="user:*")
async def update_user(user_id: UUID, data: UserUpdate) -> User:
    return await repo.update(user_id, data)
```

### 9.3 Implementation

```python
def cached(
    ttl: int = 60,
    key_builder: Callable[..., str] | None = None,
    namespace: str = "cache",
):
    def decorator(func: Callable[P, Awaitable[T]]) -> Callable[P, Awaitable[T]]:
        @wraps(func)
        async def wrapper(*args: P.args, **kwargs: P.kwargs) -> T:
            # Build cache key
            if key_builder:
                key = f"{namespace}:{key_builder(*args, **kwargs)}"
            else:
                key = f"{namespace}:{func.__name__}:{hash((args, tuple(kwargs.items())))}"

            # Check cache
            cached_value = await redis.get(key)
            if cached_value:
                return deserialize(cached_value)

            # Execute and cache
            result = await func(*args, **kwargs)
            await redis.setex(key, ttl, serialize(result))
            return result

        return wrapper
    return decorator
```

### 9.4 Cache Invalidation Patterns

| Pattern                | Use Case                         |
| ---------------------- | -------------------------------- |
| `user:{id}`            | Single entity invalidation       |
| `user:*`               | All users (after bulk operation) |
| `tenant:{tenant_id}:*` | All tenant data                  |
| `list:users:*`         | All user list caches             |

---

## 10. Background Jobs

### 10.1 Stack: ARQ (Async Redis Queue)

**Why ARQ:**

- Async-native (no thread pool overhead)
- Simple API
- Redis-based (already in stack)
- Built-in retry, scheduling, job results

### 10.2 Worker Configuration

```python
# src/app/core/jobs/worker.py
from arq import cron
from arq.connections import RedisSettings

async def startup(ctx: dict):
    """Initialize resources for worker."""
    ctx["db"] = await create_async_engine()
    ctx["redis"] = await create_redis_pool()

async def shutdown(ctx: dict):
    """Cleanup resources."""
    await ctx["db"].dispose()
    await ctx["redis"].close()

class WorkerSettings:
    functions = [
        send_email,
        process_webhook,
        generate_report,
        cleanup_expired_tokens,
    ]
    cron_jobs = [
        cron(cleanup_expired_tokens, hour=3, minute=0),  # Daily at 3 AM
        cron(send_digest_emails, hour=9, minute=0),      # Daily at 9 AM
    ]
    on_startup = startup
    on_shutdown = shutdown
    redis_settings = RedisSettings.from_dsn(settings.REDIS_URL)
    max_jobs = 10
    job_timeout = 300  # 5 minutes
    retry_jobs = True
    max_tries = 3
```

### 10.3 Job Definition

```python
# src/app/core/jobs/tasks/email.py
from arq import Retry

async def send_email(
    ctx: dict,
    to: str,
    subject: str,
    template: str,
    context: dict,
):
    """Send email via configured provider."""
    try:
        async with ctx["email_client"] as client:
            await client.send(
                to=to,
                subject=subject,
                html=render_template(template, context),
            )
    except TemporaryError as e:
        # Retry with exponential backoff
        raise Retry(defer=ctx["job_try"] * 60)
```

### 10.4 Enqueueing Jobs

```python
# From anywhere in the application
from app.core.jobs import enqueue

await enqueue(
    "send_email",
    to="user@example.com",
    subject="Welcome!",
    template="welcome.html",
    context={"name": "John"},
)

# With delay
await enqueue(
    "send_reminder",
    _defer_by=timedelta(hours=24),
    user_id=user.id,
)
```

---

## 11. Observability

### 11.1 Structured Logging

**Stack:** Structlog with JSON output in production

```python
# Configuration
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.JSONRenderer() if production else structlog.dev.ConsoleRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
    context_class=dict,
    logger_factory=structlog.PrintLoggerFactory(),
    cache_logger_on_first_use=True,
)
```

**Usage:**

```python
from structlog import get_logger

log = get_logger()

async def create_user(data: UserCreate):
    log.info("creating_user", email=data.email)
    user = await repo.create(data)
    log.info("user_created", user_id=str(user.id))
    return user
```

**Log Output:**

```json
{
  "event": "user_created",
  "user_id": "550e8400-e29b-41d4-a716-446655440000",
  "level": "info",
  "timestamp": "2024-01-15T10:30:00Z",
  "request_id": "abc123",
  "tenant_id": "tenant_456"
}
```

### 11.2 Distributed Tracing

**Stack:** OpenTelemetry with OTLP export

```python
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor

def setup_tracing(app: FastAPI):
    # Auto-instrument frameworks
    FastAPIInstrumentor.instrument_app(app)
    SQLAlchemyInstrumentor().instrument(engine=engine)
    RedisInstrumentor().instrument()

    # Configure exporter
    tracer_provider = TracerProvider(
        resource=Resource.create({"service.name": "agency-standard"})
    )
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=settings.OTLP_ENDPOINT))
    )
    trace.set_tracer_provider(tracer_provider)
```

### 11.3 Health Checks

```python
@router.get("/health/live")
async def liveness():
    """Kubernetes liveness probe. Is the process running?"""
    return {"status": "alive"}

@router.get("/health/ready")
async def readiness(
    db: AsyncSession = Depends(get_db),
    redis: Redis = Depends(get_redis),
):
    """Kubernetes readiness probe. Can we serve traffic?"""
    checks = {}

    # Database check
    try:
        await db.execute(text("SELECT 1"))
        checks["database"] = "ok"
    except Exception as e:
        checks["database"] = str(e)

    # Redis check
    try:
        await redis.ping()
        checks["redis"] = "ok"
    except Exception as e:
        checks["redis"] = str(e)

    all_ok = all(v == "ok" for v in checks.values())
    return JSONResponse(
        status_code=200 if all_ok else 503,
        content={"status": "ready" if all_ok else "degraded", "checks": checks},
    )
```

### 11.4 Metrics (Optional)

```python
from prometheus_client import Counter, Histogram

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)

REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "endpoint"],
)
```

---

## 12. Audit Logging

### 12.1 Purpose

Track who did what, when, for compliance and debugging.

### 12.2 Audit Log Model

```python
class AuditLog(Base):
    __tablename__ = "audit_logs"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    tenant_id: Mapped[UUID] = mapped_column(ForeignKey("tenants.id"))
    user_id: Mapped[UUID | None] = mapped_column(ForeignKey("users.id"))

    # What happened
    action: Mapped[str]           # "create", "update", "delete", "login"
    resource_type: Mapped[str]    # "user", "project", "settings"
    resource_id: Mapped[str | None]

    # Context
    ip_address: Mapped[str | None]
    user_agent: Mapped[str | None]
    request_id: Mapped[str | None]

    # Data
    changes: Mapped[dict | None] = mapped_column(JSONB)  # {"field": {"old": x, "new": y}}
    metadata: Mapped[dict | None] = mapped_column(JSONB)

    # Timestamp
    created_at: Mapped[datetime] = mapped_column(default=datetime.utcnow)
```

### 12.3 Automatic Capture

```python
class AuditMiddleware:
    """Captures model changes for audit logging."""

    @event.listens_for(Session, "before_flush")
    def before_flush(session, flush_context, instances):
        for obj in session.dirty:
            if hasattr(obj, "__audit__") and obj.__audit__:
                changes = {}
                for attr in inspect(obj).attrs:
                    hist = attr.history
                    if hist.has_changes():
                        changes[attr.key] = {
                            "old": hist.deleted[0] if hist.deleted else None,
                            "new": hist.added[0] if hist.added else None,
                        }
                if changes:
                    session.add(AuditLog(
                        action="update",
                        resource_type=obj.__tablename__,
                        resource_id=str(obj.id),
                        changes=changes,
                    ))
```

### 12.4 Manual Audit Entries

```python
class AuditService:
    async def log(
        self,
        action: str,
        resource_type: str,
        resource_id: str | None = None,
        metadata: dict | None = None,
    ):
        await self.repo.create(AuditLog(
            tenant_id=self.context.tenant_id,
            user_id=self.context.user_id,
            action=action,
            resource_type=resource_type,
            resource_id=resource_id,
            ip_address=self.context.ip_address,
            user_agent=self.context.user_agent,
            request_id=self.context.request_id,
            metadata=metadata,
        ))

# Usage
await audit.log("export", "report", report_id, {"format": "csv", "rows": 1500})
```

---

## 13. Testing Infrastructure

### 13.1 Test Database Strategy

**Approach:** Transaction rollback per test

```python
# tests/conftest.py
import pytest
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession

@pytest.fixture(scope="session")
async def engine():
    """Create test database engine."""
    engine = create_async_engine(settings.TEST_DATABASE_URL)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)

@pytest.fixture
async def db(engine):
    """Provide transactional database session."""
    async with engine.connect() as conn:
        await conn.begin()
        async with AsyncSession(conn, expire_on_commit=False) as session:
            yield session
        await conn.rollback()
```

### 13.2 Factories (Polyfactory)

```python
# tests/factories/user.py
from polyfactory.factories.pydantic_factory import ModelFactory
from app.modules.users.models import User

class UserFactory(ModelFactory):
    __model__ = User

    @classmethod
    def email(cls) -> str:
        return f"{cls.__faker__.user_name()}@example.com"

    @classmethod
    def tenant_id(cls) -> UUID:
        # Override in tests that need specific tenant
        return uuid4()

# Usage in tests
user = UserFactory.build()  # In-memory only
user = await UserFactory.create_async(db)  # Persisted
users = UserFactory.batch(10)  # Multiple instances
```

### 13.3 API Testing

```python
# tests/integration/api/test_users.py
import pytest
from httpx import AsyncClient

@pytest.fixture
async def client(app, db):
    async with AsyncClient(app=app, base_url="http://test") as client:
        yield client

@pytest.fixture
async def authenticated_client(client, user):
    token = create_access_token(user)
    client.headers["Authorization"] = f"Bearer {token}"
    return client

async def test_create_user(authenticated_client, db):
    response = await authenticated_client.post(
        "/api/v1/users",
        json={"email": "new@example.com", "name": "New User"},
    )
    assert response.status_code == 201
    data = response.json()
    assert data["email"] == "new@example.com"

async def test_create_user_duplicate_email(authenticated_client, user):
    response = await authenticated_client.post(
        "/api/v1/users",
        json={"email": user.email, "name": "Duplicate"},
    )
    assert response.status_code == 409
    assert response.json()["type"] == "https://api.example.com/errors/conflict"
```

### 13.4 Test Configuration

```toml
# pyproject.toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
addopts = [
    "-v",
    "--tb=short",
    "--strict-markers",
    "-ra",
]
markers = [
    "unit: Unit tests (no I/O)",
    "integration: Integration tests (database, redis)",
    "e2e: End-to-end tests (full stack)",
    "slow: Slow tests (excluded by default)",
]
filterwarnings = [
    "ignore::DeprecationWarning",
]

[tool.coverage.run]
source = ["src"]
branch = true

[tool.coverage.report]
exclude_lines = [
    "pragma: no cover",
    "if TYPE_CHECKING:",
    "raise NotImplementedError",
]
```

---

## 14. CI/CD Pipeline

### 14.1 GitHub Actions Workflow

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  PYTHON_VERSION: "3.12"
  UV_VERSION: "0.4.0"

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install uv
        uses: astral-sh/setup-uv@v3
        with:
          version: ${{ env.UV_VERSION }}

      - name: Set up Python
        run: uv python install ${{ env.PYTHON_VERSION }}

      - name: Install dependencies
        run: uv sync --frozen

      - name: Lint with Ruff
        run: uv run ruff check .

      - name: Format check
        run: uv run ruff format --check .

      - name: Type check
        run: uv run mypy src

      - name: Architecture check
        run: uv run tach check

  test:
    runs-on: ubuntu-latest
    needs: lint

    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
          POSTGRES_DB: test
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

      redis:
        image: redis:7
        ports:
          - 6379:6379

    steps:
      - uses: actions/checkout@v4

      - name: Install uv
        uses: astral-sh/setup-uv@v3
        with:
          version: ${{ env.UV_VERSION }}

      - name: Set up Python
        run: uv python install ${{ env.PYTHON_VERSION }}

      - name: Install dependencies
        run: uv sync --frozen --all-extras

      - name: Run tests
        env:
          DATABASE_URL: postgresql+asyncpg://test:test@localhost:5432/test
          REDIS_URL: redis://localhost:6379
        run: uv run pytest --cov --cov-report=xml

      - name: Check migrations
        env:
          DATABASE_URL: postgresql+asyncpg://test:test@localhost:5432/test
        run: uv run python scripts/check_migrations.py

      - name: Upload coverage
        uses: codecov/codecov-action@v4
        with:
          files: ./coverage.xml

  build:
    runs-on: ubuntu-latest
    needs: test
    if: github.ref == 'refs/heads/main'

    steps:
      - uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build image
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./deploy/Dockerfile
          push: false
          tags: agency-standard:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

### 14.2 Migration Safety Check

```python
# scripts/check_migrations.py
"""
Verify that models match migrations.
Fails CI if there are pending model changes not captured in migrations.
"""
import subprocess
import sys

def main():
    # Generate migration to see if anything is pending
    result = subprocess.run(
        ["alembic", "revision", "--autogenerate", "-m", "ci_check", "--dry-run"],
        capture_output=True,
        text=True,
    )

    # Check if any changes detected
    if "No changes in schema detected" not in result.stdout:
        print("❌ Pending model changes not captured in migrations:")
        print(result.stdout)
        sys.exit(1)

    print("✅ Models and migrations are in sync")
    sys.exit(0)

if __name__ == "__main__":
    main()
```

---

## 15. AI Context Layer

### 15.1 Purpose

Provide ground truth to AI coding assistants (Cursor, Claude, Copilot) to reduce hallucinations and improve code generation quality.

### 15.2 Files

**`.cursorrules`** — Rules of engagement for AI

```markdown
# Agency Standard - AI Coding Rules

## Architecture

- This is a FastAPI application using SQLAlchemy 2.0 async
- Follow the Service-Repository pattern strictly
- Never import repositories from routes; always go through services

## Conventions

- Use `Annotated[X, Depends(Y)]` for dependency injection
- All endpoints must have `response_model` and `summary`
- Use Pydantic `BaseModel` for all request/response schemas
- Database models inherit from `app.core.database.Base`

## File Locations

- Routes: `src/app/modules/{module}/routes.py`
- Services: `src/app/modules/{module}/services.py`
- Repos: `src/app/modules/{module}/repos.py`
- Models: `src/app/modules/{module}/models.py`
- Schemas: `src/app/modules/{module}/schemas.py`

## Testing

- Unit tests: `tests/unit/`
- Integration tests: `tests/integration/`
- Use factories from `tests/factories/`

## Commands

- `just test` — Run all tests
- `just lint` — Lint and type-check
- `just migrate` — Run migrations
- `just seed` — Generate demo data
```

**`.llms/CONTEXT.md`** — Project overview

```markdown
# Agency Standard - Project Context

## Overview

A multi-tenant SaaS backend built with FastAPI and PostgreSQL.

## Key Patterns

### Multi-Tenancy

Every request has a tenant context. Repositories automatically filter by tenant_id.
Never query without tenant context unless explicitly bypassing for admin operations.

### Authentication

JWT tokens with 15-minute expiry. Refresh tokens in HTTP-only cookies.
OAuth2 supported for Google, Microsoft, GitHub.

### Permissions

RBAC system with roles and permissions. Use `@require_permission("resource", "action")`.

## Database Schema

See `schema.sql` for current structure.

## API Specification

See `openapi.yaml` for all endpoints.
```

**`.llms/PATTERNS.md`** — Code examples

````markdown
# Code Patterns

## Creating a New Endpoint

```python
@router.post(
    "/items",
    response_model=ItemResponse,
    status_code=201,
    summary="Create a new item",
    tags=["items"],
)
async def create_item(
    data: ItemCreate,
    service: Annotated[ItemService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> ItemResponse:
    item = await service.create(data)
    return ItemResponse.model_validate(item)
```
````

## Creating a New Service

```python
class ItemService:
    def __init__(
        self,
        repo: Annotated[ItemRepository, Depends()],
        context: Annotated[RequestContext, Depends()],
    ):
        self.repo = repo
        self.context = context

    async def create(self, data: ItemCreate) -> Item:
        return await self.repo.create(
            Item(
                tenant_id=self.context.tenant_id,
                created_by=self.context.user_id,
                **data.model_dump(),
            )
        )
```

## Creating a New Repository

```python
class ItemRepository:
    def __init__(self, session: Annotated[TenantSession, Depends()]):
        self.session = session

    async def create(self, item: Item) -> Item:
        self.session.add(item)
        await self.session.flush()
        return item

    async def get(self, item_id: UUID) -> Item | None:
        return await self.session.get(Item, item_id)
```

````

### 15.3 Auto-Generation Script

```python
# scripts/update_context.py
"""Regenerate AI context files from current codebase."""
import subprocess
from pathlib import Path

def generate_schema():
    """Dump current database schema."""
    result = subprocess.run(
        ["pg_dump", "--schema-only", "--no-owner", settings.DATABASE_URL],
        capture_output=True,
        text=True,
    )
    Path(".llms/schema.sql").write_text(result.stdout)

def generate_openapi():
    """Export OpenAPI spec from FastAPI."""
    from app.main import create_app
    import json

    app = create_app()
    spec = app.openapi()
    Path(".llms/openapi.yaml").write_text(yaml.dump(spec))

def main():
    generate_schema()
    generate_openapi()
    print("✅ AI context updated")

if __name__ == "__main__":
    main()
````

---

## 16. Deployment

### 16.1 Dockerfile (Production)

```dockerfile
# deploy/Dockerfile
# Stage 1: Build
FROM python:3.12-slim as builder

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Set up environment
ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy

WORKDIR /app

# Install dependencies (cached layer)
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# Copy application
COPY src ./src
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# Stage 2: Runtime
FROM python:3.12-slim

# Security: non-root user
RUN useradd --create-home appuser
WORKDIR /app

# Copy virtual environment
COPY --from=builder /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"

# Copy application
COPY --from=builder /app/src ./src
COPY alembic.ini ./
COPY scripts ./scripts

# Switch to non-root user
USER appuser

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health/live || exit 1

# Run
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000"]
```

### 16.2 Docker Compose (Production)

```yaml
# deploy/docker-compose.prod.yml
version: "3.9"

services:
  app:
    build:
      context: ..
      dockerfile: deploy/Dockerfile
    restart: unless-stopped
    env_file: .env.prod
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - internal
      - web
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app.rule=Host(`api.example.com`)"
      - "traefik.http.routers.app.tls.certresolver=letsencrypt"

  worker:
    build:
      context: ..
      dockerfile: deploy/Dockerfile
    command: arq app.core.jobs.worker.WorkerSettings
    restart: unless-stopped
    env_file: .env.prod
    depends_on:
      - redis
      - postgres
    networks:
      - internal

  postgres:
    image: postgres:16
    restart: unless-stopped
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER}"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - internal

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - internal

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - web

volumes:
  postgres_data:
  redis_data:
  caddy_data:
  caddy_config:

networks:
  internal:
  web:
```

### 16.3 Caddyfile

```caddyfile
# deploy/Caddyfile
{
    email admin@example.com
}

api.example.com {
    reverse_proxy app:8000 {
        health_uri /health/live
        health_interval 30s
    }

    encode gzip

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
    }

    log {
        output stdout
        format json
    }
}
```

---

## 17. Justfile (Command Interface)

```justfile
# justfile - The command interface for humans and AI

set dotenv-load

# Default: show available commands
default:
    @just --list

# ============================================================
# DEVELOPMENT
# ============================================================

# Start development environment
dev:
    docker compose -f deploy/docker-compose.yml up -d postgres redis
    uvicorn app.main:create_app --factory --reload

# Start background worker
worker:
    arq app.core.jobs.worker.WorkerSettings

# Run interactive shell
shell:
    python -m IPython

# ============================================================
# TESTING
# ============================================================

# Run all tests
test *args:
    pytest {{args}}

# Run unit tests only
test-unit:
    pytest tests/unit -v

# Run integration tests only
test-integration:
    pytest tests/integration -v

# Run with coverage
test-cov:
    pytest --cov=src --cov-report=html --cov-report=term

# ============================================================
# CODE QUALITY
# ============================================================

# Run all linters
lint:
    ruff check .
    ruff format --check .
    mypy src
    tach check

# Fix auto-fixable issues
fix:
    ruff check --fix .
    ruff format .

# Type check only
typecheck:
    mypy src

# Architecture check only
archcheck:
    tach check

# ============================================================
# DATABASE
# ============================================================

# Run all pending migrations
migrate:
    alembic upgrade head

# Create a new migration
migration name:
    alembic revision --autogenerate -m "{{name}}"

# Rollback last migration
rollback:
    alembic downgrade -1

# Reset database (DANGEROUS)
db-reset:
    alembic downgrade base
    alembic upgrade head

# Check migrations match models (CI)
db-check:
    python scripts/check_migrations.py

# ============================================================
# SEED DATA
# ============================================================

# Generate demo data
seed:
    python scripts/seed.py

# Seed with specific scenario
seed-scenario scenario:
    python scripts/seed.py --scenario {{scenario}}

# ============================================================
# AI CONTEXT
# ============================================================

# Update AI context files
update-context:
    python scripts/update_context.py

# ============================================================
# FRONTEND BRIDGE
# ============================================================

# Generate TypeScript client from OpenAPI
gen-client:
    npx openapi-ts --input http://localhost:8000/openapi.json --output ../frontend/src/api

# ============================================================
# DEPLOYMENT
# ============================================================

# Build production image
build:
    docker build -f deploy/Dockerfile -t agency-standard:latest .

# Deploy to production
deploy:
    docker compose -f deploy/docker-compose.prod.yml up -d

# View production logs
logs service="app":
    docker compose -f deploy/docker-compose.prod.yml logs -f {{service}}

# ============================================================
# UTILITIES
# ============================================================

# Generate secret key
secret:
    python -c "import secrets; print(secrets.token_urlsafe(32))"

# Open documentation
docs:
    mkdocs serve

# Clean temporary files
clean:
    find . -type d -name __pycache__ -exec rm -rf {} +
    find . -type d -name .pytest_cache -exec rm -rf {} +
    find . -type d -name .mypy_cache -exec rm -rf {} +
    find . -type d -name .ruff_cache -exec rm -rf {} +
    rm -rf htmlcov .coverage coverage.xml
```

---

## 18. Configuration Management

### 18.1 Settings

```python
# src/app/config.py
from pydantic import PostgresDsn, RedisDsn, computed_field
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )

    # Application
    app_name: str = "Agency Standard"
    debug: bool = False
    environment: str = "development"  # development, staging, production
    secret_key: str

    # Database
    database_url: PostgresDsn
    database_pool_size: int = 5
    database_max_overflow: int = 10

    # Redis
    redis_url: RedisDsn

    # Auth
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 7

    # OAuth (optional)
    google_client_id: str | None = None
    google_client_secret: str | None = None
    microsoft_client_id: str | None = None
    microsoft_client_secret: str | None = None
    github_client_id: str | None = None
    github_client_secret: str | None = None

    # Rate Limiting
    rate_limit_requests: int = 100
    rate_limit_window: int = 60

    # Observability
    otlp_endpoint: str | None = None
    log_level: str = "INFO"

    @computed_field
    @property
    def async_database_url(self) -> str:
        return str(self.database_url).replace("postgresql://", "postgresql+asyncpg://")

settings = Settings()
```

### 18.2 Environment Template

```bash
# .env.example

# Application
APP_NAME="My SaaS"
DEBUG=false
ENVIRONMENT=development
SECRET_KEY=  # Generate with: just secret

# Database
DATABASE_URL=postgresql://user:password@localhost:5432/myapp

# Redis
REDIS_URL=redis://localhost:6379

# OAuth (optional)
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=

# Observability (optional)
OTLP_ENDPOINT=
LOG_LEVEL=INFO
```

---

## 19. Module Interface Specification

For future cartridges and custom modules, all modules must follow this interface:

### 19.1 Required Files

```
modules/{name}/
├── __init__.py        # Module registration
├── routes.py          # FastAPI router
├── schemas.py         # Pydantic models
├── services.py        # Business logic
├── repos.py           # Data access
├── models.py          # SQLAlchemy models
└── migrations/
    └── versions/      # Alembic migrations
```

### 19.2 Module Registration

```python
# modules/{name}/__init__.py
from fastapi import APIRouter

router = APIRouter(prefix="/{name}", tags=["{name}"])

# Import routes to register them
from . import routes  # noqa: F401, E402

# Module metadata
__module__ = {
    "name": "{name}",
    "version": "1.0.0",
    "description": "Description of module",
    "dependencies": [],  # Other required modules
}
```

### 19.3 Auto-Discovery

```python
# src/app/modules/__init__.py
from importlib import import_module
from pathlib import Path

def discover_modules():
    """Auto-discover and register all modules."""
    modules_dir = Path(__file__).parent
    routers = []

    for path in modules_dir.iterdir():
        if path.is_dir() and not path.name.startswith("_"):
            try:
                module = import_module(f"app.modules.{path.name}")
                if hasattr(module, "router"):
                    routers.append(module.router)
            except ImportError as e:
                logger.warning(f"Failed to load module {path.name}: {e}")

    return routers
```

---

## 20. Development Phases

### Phase 1: Foundation (Week 1-2)

- [x] Project scaffolding (copier.yml, pyproject.toml)
- [x] Docker development environment
- [x] Database setup (engine, session, base model)
- [x] Configuration management
- [x] Basic FastAPI app structure
- [x] Justfile with core commands

### Phase 2: Core Services (Week 3-4)

- [x] Authentication (JWT, refresh tokens)
- [x] OAuth2 integration (Google, Microsoft, GitHub)
- [x] Tenant context middleware
- [x] Permission system (RBAC)
- [x] Error handling (RFC 7807)
- [x] Request logging

### Phase 3: Infrastructure (Week 5-6)

- [x] Rate limiting
- [x] Caching layer
- [x] Background jobs (ARQ)
- [x] Audit logging
- [x] Health checks

### Phase 4: Quality & Observability (Week 7)

- [x] Testing infrastructure
- [x] CI/CD pipeline
- [x] OpenTelemetry tracing
- [x] Structured logging
- [x] Architecture enforcement (tach)

### Phase 5: AI Layer & Docs (Week 8)

- [x] AI context files
- [x] Context generation script
- [x] .cursorrules
- [x] MkDocs documentation
- [x] README and getting started guide

### Phase 6: Polish & Deploy (Week 9-10)

- [x] Production Dockerfile
- [x] Docker Compose production stack
- [x] Caddy configuration
- [x] Demo seeding
- [x] TypeScript client generator
- [x] Final testing and documentation review

---

## 21. Success Criteria

The core is complete when:

1. **Scaffold to authenticated endpoint in < 30 minutes**
   - Run copier, configure env, start Docker, create migration, hit authenticated API

2. **All tests pass**
   - Unit, integration, and architecture tests green
   - Coverage > 80%

3. **Documentation complete**
   - Getting started guide
   - Architecture documentation
   - API reference (auto-generated)

4. **Production deployable**
   - Single `docker compose up` deploys full stack
   - HTTPS working via Caddy
   - Health checks passing

5. **AI context working**
   - Cursor can generate correct code using .cursorrules
   - Context files accurately reflect codebase

---

## Appendix A: Excluded from Core

The following features are intentionally excluded from the core and planned as future cartridges:

- **Billing/Payments** (Stripe integration)
- **File Storage** (S3/R2 uploads)
- **Email Templates** (MJML compilation)
- **AI/RAG** (Vector search, embeddings)
- **Admin Dashboard** (SQLAdmin)
- **Webhooks** (Incoming webhook handling)
- **Notifications** (Push, SMS, Slack)

Each of these will follow the Module Interface Specification when implemented.

---

## Appendix B: Tooling Benchmarks

To validate "Rust-era" tooling claims, measure and document:

| Operation              | Legacy Tool            | Time | New Tool | Time | Speedup |
| ---------------------- | ---------------------- | ---- | -------- | ---- | ------- |
| Dependency resolution  | Poetry                 | TBD  | uv       | TBD  | TBD     |
| Linting (full project) | Flake8 + isort + black | TBD  | Ruff     | TBD  | TBD     |
| Type checking          | Mypy                   | TBD  | Mypy     | N/A  | N/A     |

Populate with real measurements during development.

---

_Document Version: 4.0.0_  
_Last Updated: [Date]_  
_Status: Ready for Build_
