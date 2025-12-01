# Agency Standard Python Kit

A production-ready Python backend kit for software agencies. Built with FastAPI, SQLAlchemy 2.0 async, and multi-tenancy support out of the box.

## Why Agency Standard?

**Save 20-30 hours of project setup.** Ship your first authenticated, multi-tenant endpoint in under an hour.

<div class="grid cards" markdown>

-   :material-rocket-launch:{ .lg .middle } **Production Ready**

    ---

    Not a boilerplate. A complete, deployable backend with authentication, permissions, caching, and background jobs.

-   :material-account-group:{ .lg .middle } **Multi-Tenant First**

    ---

    Row-level tenant isolation baked in from day one. Every query automatically scopes to the current tenant.

-   :material-robot:{ .lg .middle } **AI-Assisted Development**

    ---

    Structured for LLM comprehension with context files, strict typing, and consistent patterns.

-   :material-speedometer:{ .lg .middle } **Modern Python Tooling**

    ---

    "Rust-era" tools: uv for packages (10-100x faster), Ruff for linting, strict Mypy typing.

</div>

## Core Features

| Feature | Description |
|---------|-------------|
| **FastAPI** | Async-native, automatic OpenAPI docs, Pydantic v2 validation |
| **SQLAlchemy 2.0** | Async PostgreSQL, type-safe queries, mature ecosystem |
| **Multi-Tenancy** | Row-level isolation with automatic tenant context |
| **Authentication** | JWT tokens, OAuth2 (Google, Microsoft, GitHub), refresh tokens |
| **Permissions** | RBAC with roles and fine-grained permissions |
| **Background Jobs** | ARQ (async Redis queue) for background processing |
| **Caching** | Redis with decorator-based caching and invalidation |
| **Rate Limiting** | Sliding window rate limiting per user/tenant |
| **Audit Logging** | Automatic tracking of who did what, when |
| **Observability** | OpenTelemetry tracing, structured logging |

## Quick Start

```bash
# Clone the repository
git clone https://github.com/example/agency-python-starter-kit
cd agency-python-starter-kit

# Install dependencies
just install

# Start PostgreSQL and Redis
just services

# Run database migrations
just migrate

# Start development server
just dev
```

The API will be available at [http://localhost:8000](http://localhost:8000)

- **API Docs**: [http://localhost:8000/docs](http://localhost:8000/docs)
- **Health Check**: [http://localhost:8000/health/live](http://localhost:8000/health/live)

## Architecture at a Glance

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
│  (Auth, Permissions, Jobs, Cache, Rate Limit, Logging)       │
├─────────────────────────────────────────────────────────────┤
│                    Data Layer                                │
│  (Repositories, Models, Database Sessions)                   │
└─────────────────────────────────────────────────────────────┘
```

The application follows a **Modular Monolith** pattern with strict layering:

```
Routes → Services → Repositories → Models
```

See [Architecture Overview](architecture/overview.md) for details.

## Next Steps

- [Getting Started](getting-started.md) - Detailed setup and your first endpoint
- [Architecture](architecture/overview.md) - Understand the system design
- [API Design](api/overview.md) - API conventions and standards
- [Deployment](deployment/docker.md) - Docker and production deployment

