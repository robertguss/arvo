# Arvo

A CLI for scaffolding production-ready Python backend projects and managing cartridges (plugins).

## Features

- **Scaffold Projects** - `arvo new my-app` creates a complete FastAPI application
- **Cartridges** - Add features like billing, storage, and email with `arvo add`
- **Production Ready** - Multi-tenancy, authentication, background jobs, and more
- **Modern Python** - Python 3.12+, async, strict typing

## Installation

```bash
# Install via pip
pip install arvo

# Or via uv
uv tool install arvo

# Or run without installing
uvx arvo new my-app
```

## Quick Start

```bash
# Create a new project
arvo new my-saas-app

# Navigate to the project
cd my-saas-app

# Install dependencies
uv sync

# Start PostgreSQL and Redis
just services

# Run database migrations
just migrate

# Start development server
just dev
```

Your API will be available at http://localhost:8000

## Commands

### `arvo new <project-name>`

Create a new Arvo project with all production-ready features:

```bash
arvo new my-app
arvo new my-app --output ./projects
arvo new my-app --no-git
```

### `arvo list`

List available cartridges:

```bash
arvo list
arvo list --installed  # Show only installed cartridges
```

### `arvo add <cartridge>`

Add a cartridge (plugin) to your project:

```bash
arvo add billing    # Stripe billing integration
arvo add storage    # S3/R2 file storage
arvo add email      # Email templates
```

### `arvo remove <cartridge>`

Remove a cartridge from your project:

```bash
arvo remove billing
arvo remove billing --force  # Skip confirmation
```

### `arvo update [cartridge]`

Update installed cartridges:

```bash
arvo update           # Check all for updates
arvo update billing   # Update specific cartridge
arvo update --check   # Just check, don't install
```

## What's Included in Generated Projects

- **FastAPI** with async support and OpenAPI documentation
- **SQLAlchemy 2.0** with async PostgreSQL
- **Multi-tenancy** with row-level isolation
- **Authentication** - JWT, OAuth2 (Google, Microsoft, GitHub)
- **RBAC Permissions** - Role-based access control
- **Background Jobs** - ARQ (async Redis queue)
- **Caching** - Redis with decorator-based caching
- **Rate Limiting** - Sliding window rate limiting
- **Audit Logging** - Track who did what, when
- **Observability** - OpenTelemetry tracing, structured logging
- **Docker** - Development and production configurations
- **Caddy** - Reverse proxy with automatic HTTPS

## Available Cartridges

| Cartridge | Description |
|-----------|-------------|
| `billing` | Stripe integration with subscriptions, invoices, metered billing |
| `storage` | S3/R2 file uploads with presigned URLs |
| `email` | Email templates with MJML |
| `admin` | SQLAdmin dashboard |
| `notifications` | Push, SMS, Slack notifications |

## Development

```bash
# Clone the repository
git clone https://github.com/your-org/arvo
cd arvo

# Install dependencies
uv sync

# Run CLI in development
uv run arvo --help

# Run tests
uv run pytest
```

### Installing Locally as a Global CLI

To test the CLI from any directory (simulating a real installation):

```bash
# Install as a global tool (editable mode - changes reflect immediately)
uv tool install --editable .

# Now you can run arvo from anywhere
cd /tmp/my-test-app
arvo add billing

# Useful commands
uv tool list              # Check installed tools
uv tool uninstall arvo    # Remove when done
uv tool install --editable . --force  # Reinstall after major changes
```

## License

MIT
