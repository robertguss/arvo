# Docker Setup

The Agency Standard includes Docker configurations for both development and production environments.

## Development Setup

### Quick Start

```bash
# Start PostgreSQL and Redis
just services

# Start the development server (with hot-reload)
just dev
```

### Development Compose File

The development stack is defined in `deploy/docker-compose.yml`:

```yaml
version: "3.9"

services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: agency_standard
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:
  redis_data:
```

### Managing Services

```bash
# Start services
just services

# Stop services
just services-down

# View logs
just logs postgres
just logs redis

# Reset database (deletes all data)
docker compose -f deploy/docker-compose.yml down -v
just services
just migrate
```

## Development Dockerfile

For containerized development with hot-reload:

```dockerfile
# deploy/Dockerfile.dev
FROM python:3.12-slim

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

# Install dependencies
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --all-extras

# Copy source code (mounted as volume for hot-reload)
COPY . .

# Development server with reload
CMD ["uv", "run", "uvicorn", "app.main:create_app", "--factory", "--reload", "--host", "0.0.0.0", "--port", "8000"]
```

## Production Dockerfile

The production Dockerfile uses multi-stage builds for optimal image size:

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

# Copy virtual environment from builder
COPY --from=builder /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"

# Copy application
COPY --from=builder /app/src ./src
COPY alembic.ini ./
COPY alembic ./alembic

# Switch to non-root user
USER appuser

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health/live || exit 1

# Run
EXPOSE 8000
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000"]
```

### Build Commands

```bash
# Build production image
just build

# Or manually
docker build -f deploy/Dockerfile -t agency-standard:latest .

# Run container
docker run -p 8000:8000 \
  -e DATABASE_URL=postgresql://... \
  -e REDIS_URL=redis://... \
  -e SECRET_KEY=... \
  agency-standard:latest
```

## Image Optimization

### Layer Caching

The Dockerfile is structured to maximize cache hits:

1. Copy dependency files first (`pyproject.toml`, `uv.lock`)
2. Install dependencies (cached unless deps change)
3. Copy application code last

### Size Optimization

| Optimization        | Benefit                           |
| ------------------- | --------------------------------- |
| Multi-stage build   | Only runtime files in final image |
| Alpine-based images | Smaller base image                |
| `--no-dev` flag     | Exclude dev dependencies          |
| `.dockerignore`     | Exclude unnecessary files         |

Create a `.dockerignore` file:

```
# .dockerignore
.git
.github
.venv
__pycache__
*.pyc
*.pyo
.pytest_cache
.mypy_cache
.ruff_cache
htmlcov
.coverage
*.md
!README.md
tests/
docs/
.env*
!.env.example
```

## Environment Variables

Pass configuration via environment variables:

```bash
docker run -p 8000:8000 \
  -e DATABASE_URL="postgresql+asyncpg://user:pass@host:5432/db" \
  -e REDIS_URL="redis://host:6379" \
  -e SECRET_KEY="your-secret-key" \
  -e ENVIRONMENT="production" \
  agency-standard:latest
```

Or use an env file:

```bash
docker run -p 8000:8000 --env-file .env.prod agency-standard:latest
```

## Running Migrations

Run migrations before starting the app:

```bash
# Using docker run
docker run --rm \
  -e DATABASE_URL="..." \
  agency-standard:latest \
  alembic upgrade head

# Or in docker-compose
docker compose exec app alembic upgrade head
```

## Background Worker

Run the ARQ worker as a separate container:

```bash
docker run \
  -e DATABASE_URL="..." \
  -e REDIS_URL="..." \
  agency-standard:latest \
  arq app.core.jobs.worker.WorkerSettings
```

## Health Checks

The container includes a health check:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health/live || exit 1
```

Kubernetes/Docker will:

- Wait 5 seconds before first check (`start-period`)
- Check every 30 seconds (`interval`)
- Mark unhealthy after 3 failures (`retries`)

## Docker Compose Development

Full development stack with the app containerized:

```yaml
# deploy/docker-compose.dev.yml
version: "3.9"

services:
  app:
    build:
      context: ..
      dockerfile: deploy/Dockerfile.dev
    ports:
      - "8000:8000"
    volumes:
      - ../src:/app/src # Hot-reload
    environment:
      - DATABASE_URL=postgresql+asyncpg://postgres:postgres@postgres:5432/agency_standard
      - REDIS_URL=redis://redis:6379
      - SECRET_KEY=dev-secret-key
      - ENVIRONMENT=development
      - DEBUG=true
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: agency_standard
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:
  redis_data:
```

Run with:

```bash
docker compose -f deploy/docker-compose.dev.yml up
```

## Next Steps

- [Production Deployment](production.md) - Full production setup
- [Architecture](../architecture/overview.md) - System design
- [Getting Started](../getting-started.md) - Local development
