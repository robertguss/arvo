# justfile - The command interface for humans and AI

set dotenv-load

# Default: show available commands
default:
    @just --list

# ============================================================
# DEVELOPMENT
# ============================================================

# Install all dependencies
install:
    uv sync --all-extras

# Start development environment (database + redis)
services:
    docker compose -f deploy/docker-compose.yml up -d

# Stop development services
services-down:
    docker compose -f deploy/docker-compose.yml down

# Start development server with hot-reload
dev:
    uv run uvicorn app.main:create_app --factory --reload --host 0.0.0.0 --port 8000

# Start background worker (ARQ)
worker:
    uv run arq app.core.jobs.worker.WorkerSettings

# Run interactive Python shell
shell:
    uv run python -m IPython

# ============================================================
# TESTING
# ============================================================

# Run all tests
test *args:
    uv run pytest {{args}}

# Run unit tests only
test-unit:
    uv run pytest tests/unit -v

# Run integration tests only
test-integration:
    uv run pytest tests/integration -v

# Run tests with coverage
test-cov:
    uv run pytest --cov=src --cov-report=html --cov-report=term

# ============================================================
# CODE QUALITY
# ============================================================

# Run all linters
lint:
    uv run ruff check .
    uv run ruff format --check .
    uv run mypy src

# Fix auto-fixable issues
fix:
    uv run ruff check --fix .
    uv run ruff format .

# Type check only
typecheck:
    uv run mypy src

# Architecture check only (requires tach)
archcheck:
    uv run tach check

# ============================================================
# DATABASE
# ============================================================

# Run all pending migrations
migrate:
    uv run alembic upgrade head

# Create a new migration
migration name:
    uv run alembic revision --autogenerate -m "{{name}}"

# Rollback last migration
rollback:
    uv run alembic downgrade -1

# Reset database (DANGEROUS)
db-reset:
    uv run alembic downgrade base
    uv run alembic upgrade head

# Check migrations match models (CI)
db-check:
    uv run python scripts/check_migrations.py

# Show migration history
db-history:
    uv run alembic history

# Show current migration
db-current:
    uv run alembic current

# ============================================================
# SEED DATA
# ============================================================

# Generate demo data
seed:
    uv run python scripts/seed.py

# Seed with specific scenario
seed-scenario scenario:
    uv run python scripts/seed.py --scenario {{scenario}}

# ============================================================
# AI CONTEXT
# ============================================================

# Update AI context files
update-context:
    uv run python scripts/update_context.py

# ============================================================
# DEPLOYMENT
# ============================================================

# Build production image
build:
    docker build -f deploy/Dockerfile -t agency-standard:latest .

# Deploy to production
deploy:
    docker compose -f deploy/docker-compose.prod.yml up -d

# View logs
logs service="app":
    docker compose -f deploy/docker-compose.yml logs -f {{service}}

# ============================================================
# UTILITIES
# ============================================================

# Generate secret key
secret:
    python -c "import secrets; print(secrets.token_urlsafe(32))"

# Clean temporary files
clean:
    find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
    find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
    find . -type d -name .mypy_cache -exec rm -rf {} + 2>/dev/null || true
    find . -type d -name .ruff_cache -exec rm -rf {} + 2>/dev/null || true
    rm -rf htmlcov .coverage coverage.xml 2>/dev/null || true

# Show project structure
tree:
    tree -I '__pycache__|.git|.venv|node_modules|*.egg-info' -a

