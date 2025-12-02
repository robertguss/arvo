# Agency Standard - Code Patterns

## Creating a New Module

### 1. Create Module Structure

```
src/app/modules/{name}/
├── __init__.py
├── routes.py
├── schemas.py
├── services.py
├── repos.py
└── models.py
```

### 2. Module Registration

```python
# modules/{name}/__init__.py
from fastapi import APIRouter

router = APIRouter(prefix="/{name}", tags=["{name}"])

from . import routes  # noqa: F401, E402

__module_info__ = {
    "name": "{name}",
    "version": "1.0.0",
    "description": "Description of module",
    "dependencies": [],
}
```

## Creating a New Endpoint

```python
from typing import Annotated
from fastapi import Depends, status
from pydantic import BaseModel

class ItemCreate(BaseModel):
    name: str
    description: str | None = None

class ItemResponse(BaseModel):
    id: UUID
    name: str
    description: str | None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)

@router.post(
    "/items",
    response_model=ItemResponse,
    status_code=status.HTTP_201_CREATED,
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

## Creating a New Service

```python
from typing import Annotated
from fastapi import Depends

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

    async def get(self, item_id: UUID) -> Item | None:
        return await self.repo.get(item_id)

    async def list(self, page: int = 1, page_size: int = 20) -> list[Item]:
        return await self.repo.list(page=page, page_size=page_size)
```

## Creating a New Repository

```python
from typing import Annotated
from uuid import UUID
from fastapi import Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db

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

    async def list(self, page: int = 1, page_size: int = 20) -> list[Item]:
        offset = (page - 1) * page_size
        result = await self.session.execute(
            select(Item)
            .offset(offset)
            .limit(page_size)
            .order_by(Item.created_at.desc())
        )
        return list(result.scalars().all())
```

## Creating a New Model

```python
from uuid import UUID
from sqlalchemy import ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base, TenantMixin, TimestampMixin, UUIDMixin

class Item(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """Item model with tenant isolation."""

    __tablename__ = "items"

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    description: Mapped[str | None] = mapped_column(String(1000))
    created_by: Mapped[UUID] = mapped_column(ForeignKey("users.id"))

    # Relationships
    creator: Mapped["User"] = relationship(back_populates="items")

    def __repr__(self) -> str:
        return f"<Item(id={self.id}, name={self.name})>"
```

## Pagination Pattern

```python
from typing import Generic, TypeVar
from pydantic import BaseModel, computed_field

T = TypeVar("T")

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

# Usage
@router.get("/items", response_model=PaginatedResponse[ItemResponse])
async def list_items(
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
) -> PaginatedResponse[ItemResponse]:
    ...
```

## Testing Patterns

### Unit Test

```python
import pytest
from unittest.mock import AsyncMock

@pytest.mark.asyncio
async def test_service_creates_item():
    repo = AsyncMock(spec=ItemRepository)
    repo.create.return_value = Item(id=uuid4(), name="Test")

    service = ItemService(repo=repo, context=mock_context)
    result = await service.create(ItemCreate(name="Test"))

    assert result.name == "Test"
    repo.create.assert_called_once()
```

### Integration Test

```python
import pytest
from httpx import AsyncClient

@pytest.mark.asyncio
async def test_create_item_api(client: AsyncClient, auth_headers: dict):
    response = await client.post(
        "/api/v1/items",
        json={"name": "Test Item"},
        headers=auth_headers,
    )

    assert response.status_code == 201
    data = response.json()
    assert data["name"] == "Test Item"
```
