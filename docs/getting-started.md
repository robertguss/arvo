# Getting Started

This guide will walk you through setting up the Agency Standard Python Kit and creating your first authenticated endpoint.

## Prerequisites

Before you begin, ensure you have:

- **Python 3.12+** - [Download Python](https://python.org)
- **uv** - Fast Python package manager: `curl -LsSf https://astral.sh/uv/install.sh | sh`
- **Docker & Docker Compose** - [Install Docker](https://docs.docker.com/get-docker/)
- **just** - Command runner: `brew install just` or [other methods](https://github.com/casey/just#installation)
- **PostgreSQL client** - For `pg_dump` (optional, for AI context generation)

## Installation

### 1. Clone and Install

```bash
# Clone the repository
git clone https://github.com/example/agency-python-starter-kit
cd agency-python-starter-kit

# Install all dependencies (including dev tools)
just install
```

### 2. Configure Environment

```bash
# Copy the example environment file
cp .env.example .env

# Generate a secret key
just secret
# Copy the output and set it as SECRET_KEY in .env
```

Edit `.env` with your settings:

```bash
# Required
SECRET_KEY=your-generated-secret-key
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/agency_standard
REDIS_URL=redis://localhost:6379

# Optional
ENVIRONMENT=development
DEBUG=true
LOG_LEVEL=DEBUG
```

### 3. Start Services

```bash
# Start PostgreSQL and Redis containers
just services

# Verify they're running
docker compose -f deploy/docker-compose.yml ps
```

### 4. Initialize Database

```bash
# Run all migrations
just migrate

# (Optional) Seed demo data
just seed
```

### 5. Start Development Server

```bash
just dev
```

You should see:

```
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
INFO:     Started reloader process
```

Visit [http://localhost:8000/docs](http://localhost:8000/docs) to see the interactive API documentation.

## Project Structure

```
src/app/
├── main.py              # Application factory (create_app)
├── config.py            # Settings via pydantic-settings
├── core/                # Cross-cutting concerns
│   ├── auth/            # Authentication & authorization
│   ├── database/        # Session, base models, mixins
│   ├── cache/           # Redis caching
│   ├── jobs/            # Background job processing
│   ├── permissions/     # RBAC permission system
│   ├── rate_limit/      # Rate limiting
│   ├── audit/           # Audit logging
│   └── errors/          # RFC 7807 error handling
├── modules/             # Feature modules
│   ├── tenants/         # Multi-tenancy
│   └── users/           # User management
└── api/                 # API router and dependencies
```

## Creating Your First Module

Let's create a simple "items" module to understand the patterns.

### 1. Create Module Structure

```bash
mkdir -p src/app/modules/items
touch src/app/modules/items/{__init__,models,schemas,repos,services,routes}.py
```

### 2. Define the Model

```python
# src/app/modules/items/models.py
from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base, TenantMixin, TimestampMixin, UUIDMixin


class Item(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """Item model with tenant isolation."""

    __tablename__ = "items"

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    description: Mapped[str | None] = mapped_column(String(1000))
```

### 3. Create Schemas

```python
# src/app/modules/items/schemas.py
from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class ItemCreate(BaseModel):
    name: str
    description: str | None = None


class ItemResponse(BaseModel):
    id: UUID
    name: str
    description: str | None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)
```

### 4. Create Repository

```python
# src/app/modules/items/repos.py
from typing import Annotated
from uuid import UUID

from fastapi import Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from .models import Item


class ItemRepository:
    def __init__(self, session: Annotated[AsyncSession, Depends(get_db)]):
        self.session = session

    async def create(self, item: Item) -> Item:
        self.session.add(item)
        await self.session.flush()
        await self.session.refresh(item)
        return item

    async def get(self, item_id: UUID) -> Item | None:
        return await self.session.get(Item, item_id)

    async def list(self, tenant_id: UUID) -> list[Item]:
        result = await self.session.execute(
            select(Item)
            .where(Item.tenant_id == tenant_id)
            .order_by(Item.created_at.desc())
        )
        return list(result.scalars().all())
```

### 5. Create Service

```python
# src/app/modules/items/services.py
from typing import Annotated
from uuid import UUID

from fastapi import Depends

from .models import Item
from .repos import ItemRepository
from .schemas import ItemCreate


class ItemService:
    def __init__(self, repo: Annotated[ItemRepository, Depends()]):
        self.repo = repo

    async def create(self, data: ItemCreate, tenant_id: UUID) -> Item:
        item = Item(
            tenant_id=tenant_id,
            **data.model_dump(),
        )
        return await self.repo.create(item)

    async def get(self, item_id: UUID) -> Item | None:
        return await self.repo.get(item_id)

    async def list(self, tenant_id: UUID) -> list[Item]:
        return await self.repo.list(tenant_id)
```

### 6. Create Routes

```python
# src/app/modules/items/routes.py
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, status

from app.core.auth import get_current_user
from app.modules.users.models import User
from .schemas import ItemCreate, ItemResponse
from .services import ItemService

router = APIRouter(prefix="/items", tags=["items"])


@router.post(
    "",
    response_model=ItemResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create a new item",
)
async def create_item(
    data: ItemCreate,
    service: Annotated[ItemService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> ItemResponse:
    """Create a new item for the current tenant."""
    item = await service.create(data, current_user.tenant_id)
    return ItemResponse.model_validate(item)


@router.get(
    "",
    response_model=list[ItemResponse],
    summary="List all items",
)
async def list_items(
    service: Annotated[ItemService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> list[ItemResponse]:
    """List all items for the current tenant."""
    items = await service.list(current_user.tenant_id)
    return [ItemResponse.model_validate(item) for item in items]


@router.get(
    "/{item_id}",
    response_model=ItemResponse,
    summary="Get an item by ID",
)
async def get_item(
    item_id: UUID,
    service: Annotated[ItemService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> ItemResponse:
    """Get a specific item by ID."""
    item = await service.get(item_id)
    if not item:
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail="Item not found")
    return ItemResponse.model_validate(item)
```

### 7. Register Module

```python
# src/app/modules/items/__init__.py
from .routes import router

__all__ = ["router"]
```

Add to the API router:

```python
# In src/app/api/router.py, add:
from app.modules.items import router as items_router

api_router.include_router(items_router, prefix="/api/v1")
```

### 8. Create Migration

```bash
just migration "add items table"
just migrate
```

## Available Commands

| Command                 | Description                              |
| ----------------------- | ---------------------------------------- |
| `just dev`              | Start development server with hot-reload |
| `just test`             | Run all tests                            |
| `just test-unit`        | Run unit tests only                      |
| `just test-integration` | Run integration tests only               |
| `just lint`             | Lint and type-check                      |
| `just fix`              | Auto-fix linting issues                  |
| `just migrate`          | Run database migrations                  |
| `just migration "name"` | Create new migration                     |
| `just seed`             | Generate demo data                       |
| `just services`         | Start PostgreSQL + Redis                 |
| `just services-down`    | Stop services                            |

## Next Steps

- [Architecture Overview](architecture/overview.md) - Understand the system design
- [Multi-Tenancy](architecture/multi-tenancy.md) - How tenant isolation works
- [Authentication](api/authentication.md) - JWT and OAuth2 setup
- [Deployment](deployment/docker.md) - Deploy to production
