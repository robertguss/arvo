# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A production-ready multi-tenant SaaS backend built with FastAPI, SQLAlchemy 2.0 async, and PostgreSQL. Uses modern Python 3.12+ with strict typing.

## Commands

```bash
just dev              # Start dev server with hot-reload (port 8000)
just test             # Run all tests
just test tests/path  # Run specific test file
just test-unit        # Run unit tests only
just test-integration # Run integration tests only
just test-cov         # Run with coverage report
just lint             # Lint (ruff) + type check (mypy)
just fix              # Auto-fix linting issues
just typecheck        # Type check only
just hooks-install    # Install pre-commit hooks (run once)
just hooks            # Run all pre-commit hooks manually
just hooks-update     # Update hook versions
just services         # Start PostgreSQL + Redis via Docker
just services-down    # Stop services
just migrate          # Run database migrations
just migration "name" # Create new migration
just seed             # Generate demo data
```

## Architecture

**Modular Monolith** with strict layering:

```
Routes → Services → Repositories → Models
```

- **Routes** (`routes.py`): HTTP handling, uses `Annotated[X, Depends()]` for DI
- **Services** (`services.py`): Business logic, orchestration
- **Repositories** (`repos.py`): Data access, query building
- **Models** (`models.py`): SQLAlchemy table definitions
- **Schemas** (`schemas.py`): Pydantic request/response models

**Import rules** (enforced by Tach):
- Routes cannot import Repositories
- Services cannot import Routes
- Models import nothing

## Multi-Tenancy

Row-level isolation via `tenant_id` column. All tenant-scoped models **must** use `TenantMixin`:

```python
from app.core.database import Base, TenantMixin, TimestampMixin, UUIDMixin

class Item(Base, UUIDMixin, TimestampMixin, TenantMixin):
    __tablename__ = "items"
    name: Mapped[str] = mapped_column(String(255))
```

Never query without tenant context unless explicitly bypassing for admin operations.

## Module Structure

New modules go in `src/app/modules/{name}/`:

```
src/app/modules/{name}/
├── __init__.py     # Router + module registration
├── routes.py       # HTTP endpoints
├── schemas.py      # Pydantic models
├── services.py     # Business logic
├── repos.py        # Data access
└── models.py       # SQLAlchemy models
```

## API Conventions

All endpoints must have `response_model`, `summary`, and `tags`:

```python
@router.post(
    "/items",
    response_model=ItemResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create a new item",
    tags=["items"],
)
```

Use `Annotated[X, Depends()]` for all dependencies.

## Testing

- Unit tests: `tests/unit/` - mock dependencies, no I/O
- Integration tests: `tests/integration/` - real database
- Factories: `tests/factories/` - use polyfactory for test data
- Mark async tests with `@pytest.mark.asyncio` (auto mode enabled)

## Key Dependencies

- **uv**: Package manager (use `uv run` prefix)
- **Ruff**: Linting and formatting
- **Mypy**: Type checking (strict mode)
- **Tach**: Architecture boundary enforcement
- **pre-commit**: Git hooks for code quality (run `just hooks-install`)
- **Alembic**: Database migrations
- **ARQ**: Background jobs (Redis-based)
- **structlog**: Structured logging

## Error Handling

All errors return RFC 7807 Problem Details format with `trace_id`.
