# Agency Standard Python Kit

A production-ready Python backend kit for software agencies. Built with FastAPI, SQLAlchemy 2.0 async, and multi-tenancy support out of the box.

## Features

- **FastAPI** with async support and automatic OpenAPI documentation
- **SQLAlchemy 2.0** with async PostgreSQL (asyncpg)
- **Multi-tenancy** - Row-level isolation with automatic tenant filtering
- **Modern Python** - Python 3.12+, strict typing, Pydantic v2
- **"Rust-era" Tooling** - uv for packages, Ruff for linting, Mypy for types
- **Production Ready** - Docker, Caddy reverse proxy, automatic HTTPS

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

### Demo Data

Seed the database with demo data for testing:

```bash
# Create default tenant only
just seed

# Create comprehensive demo (tenants + users + roles + permissions)
just seed-full
```

Demo credentials after running `just seed-full`:

| Email | Password | Role |
|-------|----------|------|
| admin@acme.example.com | admin123!@# | Admin |
| member@acme.example.com | member123!@# | Member |
| viewer@acme.example.com | viewer123!@# | Viewer |

## Project Structure

```console
src/app/
├── main.py           # Application factory
├── config.py         # Settings (pydantic-settings)
├── core/
│   ├── auth/         # JWT, OAuth, authentication
│   ├── permissions/  # RBAC system
│   ├── database/     # Session, base models, mixins
│   ├── cache/        # Redis caching
│   ├── jobs/         # Background tasks (ARQ)
│   └── ...
├── modules/          # Feature modules
│   ├── tenants/      # Multi-tenancy module
│   └── users/        # User management
└── api/
    ├── router.py     # Health endpoints, module mounting
    └── dependencies.py
```

## Commands

```bash
just              # Show all available commands

# Development
just dev          # Start server with hot-reload
just worker       # Start background worker
just services     # Start PostgreSQL + Redis
just services-down # Stop services

# Database
just migrate      # Run migrations
just migration "add users table"  # Create new migration
just rollback     # Rollback last migration

# Seeding
just seed         # Create default seed data
just seed-full    # Create full demo (users + roles + permissions)

# Testing
just test         # Run all tests
just test-cov     # Run with coverage

# Code Quality
just lint         # Lint + type check
just fix          # Auto-fix linting issues

# Production
just build        # Build Docker image
just prod-up      # Start production stack
just prod-down    # Stop production stack
just prod-logs    # View production logs

# Frontend Integration
just gen-client   # Generate TypeScript client from OpenAPI

# Utilities
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

See [docs/architecture/overview.md](docs/architecture/overview.md) for detailed architecture documentation.

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

# Run only unit tests
just test-unit

# Run only integration tests
just test-integration
```

## Production Deployment

### Quick Deploy

1. **Configure environment:**

   ```bash
   cd deploy
   cp env.prod.example .env.prod
   # Edit .env.prod with your settings
   ```

2. **Set required values in `.env.prod`:**
   - `SECRET_KEY` - Generate with `just secret`
   - `DB_PASSWORD` - Strong database password
   - `DOMAIN` - Your API domain (e.g., api.example.com)
   - `ACME_EMAIL` - Email for Let's Encrypt

3. **Deploy:**

   ```bash
   just build      # Build Docker image
   just prod-up    # Start production stack
   ```

### Production Stack

The production deployment includes:

- **FastAPI App** - Your API with health checks
- **ARQ Worker** - Background job processing
- **PostgreSQL 16** - Primary database with persistence
- **Redis 7** - Caching and job queue
- **Caddy** - Reverse proxy with automatic HTTPS

### Production Commands

```bash
just prod-up              # Start all services
just prod-down            # Stop all services
just prod-logs            # View app logs
just prod-logs postgres   # View specific service logs
just prod-restart app     # Restart a service
just prod-migrate         # Run migrations in production
```

### Health Checks

- Liveness: `https://your-domain.com/health/live`
- Readiness: `https://your-domain.com/health/ready`

See [docs/deployment/production.md](docs/deployment/production.md) for detailed deployment documentation.

## Frontend Integration

Generate a TypeScript client from the OpenAPI spec:

```bash
# Start the dev server first
just dev

# Generate TypeScript types (in another terminal)
just gen-client

# Or specify a custom output path
just gen-client output="./my-frontend/src/api"
```

## License

MIT
