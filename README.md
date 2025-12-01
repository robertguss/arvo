# Agency Standard Python Kit

A production-ready Python backend kit for software agencies. Built with FastAPI, SQLAlchemy 2.0 async, and multi-tenancy support out of the box.

## Features

- **FastAPI** with async support and automatic OpenAPI documentation
- **SQLAlchemy 2.0** with async PostgreSQL (asyncpg)
- **Multi-tenancy** - Row-level isolation with automatic tenant filtering
- **Modern Python** - Python 3.12+, strict typing, Pydantic v2
- **"Rust-era" Tooling** - uv for packages, Ruff for linting, Mypy for types
- **Production Ready** - Docker, health checks, structured logging

## Quick Start

### Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) (package manager)
- Docker & Docker Compose
- [just](https://github.com/casey/just) (command runner)

### Setup

```bash
# Clone and enter the project
cd agency_python_starter_kit

# Install dependencies
just install

# Start PostgreSQL and Redis
just services

# Run database migrations
just migrate

# Start development server
just dev
```

The API will be available at <http://localhost:8000>

- API Docs: <http://localhost:8000/docs>
- Health Check: <http://localhost:8000/health/live>

## Project Structure

```console
src/app/
├── main.py           # Application factory
├── config.py         # Settings (pydantic-settings)
├── core/
│   └── database/     # Session, base models, mixins
├── modules/          # Feature modules
│   └── tenants/      # Multi-tenancy module
└── api/
    ├── router.py     # Health endpoints, module mounting
    └── dependencies.py
```

## Commands

```bash
just              # Show all available commands

# Development
just dev          # Start server with hot-reload
just services     # Start PostgreSQL + Redis
just services-down # Stop services

# Database
just migrate      # Run migrations
just migration "add users table"  # Create new migration
just rollback     # Rollback last migration

# Testing
just test         # Run all tests
just test-cov     # Run with coverage

# Code Quality
just lint         # Lint + type check
just fix          # Auto-fix linting issues
just typecheck    # Type check only

# Utilities
just seed         # Generate demo data
just clean        # Clean temporary files
just secret       # Generate secret key
```

## Configuration

Copy `.env.example` to `.env` and configure:

```bash
cp .env.example .env
```

Key environment variables:

| Variable       | Description                    | Default                                                         |
| -------------- | ------------------------------ | --------------------------------------------------------------- |
| `DATABASE_URL` | PostgreSQL connection string   | `postgresql://postgres:postgres@localhost:5432/agency_standard` |
| `REDIS_URL`    | Redis connection string        | `redis://localhost:6379`                                        |
| `SECRET_KEY`   | JWT signing key                | (generate with `just secret`)                                   |
| `ENVIRONMENT`  | development/staging/production | `development`                                                   |

## Architecture

This project follows a **Modular Monolith** architecture with strict layering:

```text
Routes → Services → Repositories → Models
```

- **Routes**: HTTP handling, request/response transformation
- **Services**: Business logic, orchestration
- **Repositories**: Data access, query building
- **Models**: SQLAlchemy table definitions

See [.llms/ARCHITECTURE.md](.llms/ARCHITECTURE.md) for detailed architecture documentation.

## Multi-Tenancy

Every tenant's data is isolated using row-level filtering. Models that need tenant isolation inherit from `TenantMixin`:

```python
from app.core.database import Base, TenantMixin, UUIDMixin, TimestampMixin

class Item(Base, UUIDMixin, TimestampMixin, TenantMixin):
    __tablename__ = "items"
    name: Mapped[str] = mapped_column(String(255))
```

## Testing

```bash
# Run all tests
just test

# Run with coverage
just test-cov

# Run specific test file
just test tests/test_health.py
```

## Docker

```bash
# Build production image
just build

# Run with Docker Compose (development)
docker compose -f deploy/docker-compose.yml up -d
```

## License

MIT
