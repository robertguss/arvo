# Module Structure

Modules are the building blocks of your application. Each module encapsulates a feature domain with its own routes, services, repositories, and models.

## Module Anatomy

Every module follows the same structure:

```
src/app/modules/{name}/
├── __init__.py      # Module registration, exports router
├── models.py        # SQLAlchemy models
├── schemas.py       # Pydantic request/response schemas
├── repos.py         # Repository (data access)
├── services.py      # Business logic
└── routes.py        # API endpoints
```

## Creating a New Module

### Step 1: Create Directory Structure

```bash
MODULE_NAME=products
mkdir -p src/app/modules/$MODULE_NAME
touch src/app/modules/$MODULE_NAME/{__init__,models,schemas,repos,services,routes}.py
```

### Step 2: Define Models

```python
# src/app/modules/products/models.py
from decimal import Decimal
from sqlalchemy import Numeric, String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base, TenantMixin, TimestampMixin, UUIDMixin


class Product(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """Product model with tenant isolation."""

    __tablename__ = "products"

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    description: Mapped[str | None] = mapped_column(String(2000))
    price: Mapped[Decimal] = mapped_column(Numeric(10, 2), nullable=False)
    sku: Mapped[str] = mapped_column(String(50), unique=True)
    is_active: Mapped[bool] = mapped_column(default=True)
```

### Step 3: Create Schemas

```python
# src/app/modules/products/schemas.py
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class ProductCreate(BaseModel):
    """Schema for creating a product."""
    name: str = Field(..., min_length=1, max_length=255)
    description: str | None = Field(None, max_length=2000)
    price: Decimal = Field(..., ge=0, decimal_places=2)
    sku: str = Field(..., min_length=1, max_length=50)


class ProductUpdate(BaseModel):
    """Schema for updating a product."""
    name: str | None = Field(None, min_length=1, max_length=255)
    description: str | None = Field(None, max_length=2000)
    price: Decimal | None = Field(None, ge=0, decimal_places=2)
    is_active: bool | None = None


class ProductResponse(BaseModel):
    """Schema for product responses."""
    id: UUID
    name: str
    description: str | None
    price: Decimal
    sku: str
    is_active: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)
```

### Step 4: Create Repository

```python
# src/app/modules/products/repos.py
from typing import Annotated
from uuid import UUID

from fastapi import Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from .models import Product


class ProductRepository:
    """Repository for product data access."""

    def __init__(self, session: Annotated[AsyncSession, Depends(get_db)]):
        self.session = session

    async def create(self, product: Product) -> Product:
        """Create a new product."""
        self.session.add(product)
        await self.session.flush()
        await self.session.refresh(product)
        return product

    async def get(self, product_id: UUID, tenant_id: UUID) -> Product | None:
        """Get a product by ID within a tenant."""
        result = await self.session.execute(
            select(Product)
            .where(Product.id == product_id)
            .where(Product.tenant_id == tenant_id)
        )
        return result.scalar_one_or_none()

    async def get_by_sku(self, sku: str, tenant_id: UUID) -> Product | None:
        """Get a product by SKU within a tenant."""
        result = await self.session.execute(
            select(Product)
            .where(Product.sku == sku)
            .where(Product.tenant_id == tenant_id)
        )
        return result.scalar_one_or_none()

    async def list(
        self,
        tenant_id: UUID,
        *,
        active_only: bool = True,
        limit: int = 100,
        offset: int = 0,
    ) -> list[Product]:
        """List products for a tenant."""
        query = (
            select(Product)
            .where(Product.tenant_id == tenant_id)
            .order_by(Product.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
        if active_only:
            query = query.where(Product.is_active == True)  # noqa: E712
        
        result = await self.session.execute(query)
        return list(result.scalars().all())

    async def update(self, product: Product, data: dict) -> Product:
        """Update a product."""
        for key, value in data.items():
            if value is not None:
                setattr(product, key, value)
        await self.session.flush()
        await self.session.refresh(product)
        return product

    async def delete(self, product: Product) -> None:
        """Delete a product."""
        await self.session.delete(product)
        await self.session.flush()
```

### Step 5: Create Service

```python
# src/app/modules/products/services.py
from typing import Annotated
from uuid import UUID

from fastapi import Depends, HTTPException, status

from .models import Product
from .repos import ProductRepository
from .schemas import ProductCreate, ProductUpdate


class ProductService:
    """Service for product business logic."""

    def __init__(self, repo: Annotated[ProductRepository, Depends()]):
        self.repo = repo

    async def create(self, data: ProductCreate, tenant_id: UUID) -> Product:
        """Create a new product."""
        # Check for duplicate SKU
        existing = await self.repo.get_by_sku(data.sku, tenant_id)
        if existing:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"Product with SKU '{data.sku}' already exists",
            )

        product = Product(
            tenant_id=tenant_id,
            **data.model_dump(),
        )
        return await self.repo.create(product)

    async def get(self, product_id: UUID, tenant_id: UUID) -> Product:
        """Get a product by ID."""
        product = await self.repo.get(product_id, tenant_id)
        if not product:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Product not found",
            )
        return product

    async def list(
        self,
        tenant_id: UUID,
        *,
        active_only: bool = True,
        limit: int = 100,
        offset: int = 0,
    ) -> list[Product]:
        """List products for a tenant."""
        return await self.repo.list(
            tenant_id,
            active_only=active_only,
            limit=limit,
            offset=offset,
        )

    async def update(
        self,
        product_id: UUID,
        data: ProductUpdate,
        tenant_id: UUID,
    ) -> Product:
        """Update a product."""
        product = await self.get(product_id, tenant_id)
        return await self.repo.update(product, data.model_dump(exclude_unset=True))

    async def delete(self, product_id: UUID, tenant_id: UUID) -> None:
        """Delete a product."""
        product = await self.get(product_id, tenant_id)
        await self.repo.delete(product)
```

### Step 6: Create Routes

```python
# src/app/modules/products/routes.py
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, status

from app.core.auth import get_current_user
from app.modules.users.models import User
from .schemas import ProductCreate, ProductResponse, ProductUpdate
from .services import ProductService

router = APIRouter(prefix="/products", tags=["products"])


@router.post(
    "",
    response_model=ProductResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create a new product",
)
async def create_product(
    data: ProductCreate,
    service: Annotated[ProductService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> ProductResponse:
    """Create a new product for the current tenant."""
    product = await service.create(data, current_user.tenant_id)
    return ProductResponse.model_validate(product)


@router.get(
    "",
    response_model=list[ProductResponse],
    summary="List products",
)
async def list_products(
    service: Annotated[ProductService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
    active_only: bool = Query(True, description="Filter to active products only"),
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
) -> list[ProductResponse]:
    """List products for the current tenant."""
    products = await service.list(
        current_user.tenant_id,
        active_only=active_only,
        limit=limit,
        offset=offset,
    )
    return [ProductResponse.model_validate(p) for p in products]


@router.get(
    "/{product_id}",
    response_model=ProductResponse,
    summary="Get a product",
)
async def get_product(
    product_id: UUID,
    service: Annotated[ProductService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> ProductResponse:
    """Get a product by ID."""
    product = await service.get(product_id, current_user.tenant_id)
    return ProductResponse.model_validate(product)


@router.patch(
    "/{product_id}",
    response_model=ProductResponse,
    summary="Update a product",
)
async def update_product(
    product_id: UUID,
    data: ProductUpdate,
    service: Annotated[ProductService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> ProductResponse:
    """Update a product."""
    product = await service.update(product_id, data, current_user.tenant_id)
    return ProductResponse.model_validate(product)


@router.delete(
    "/{product_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete a product",
)
async def delete_product(
    product_id: UUID,
    service: Annotated[ProductService, Depends()],
    current_user: Annotated[User, Depends(get_current_user)],
) -> None:
    """Delete a product."""
    await service.delete(product_id, current_user.tenant_id)
```

### Step 7: Register Module

```python
# src/app/modules/products/__init__.py
"""Products module."""
from .routes import router

__all__ = ["router"]
```

Add to the API router:

```python
# src/app/api/router.py
from app.modules.products import router as products_router

api_router.include_router(products_router, prefix="/api/v1")
```

### Step 8: Create Migration

```bash
just migration "add products table"
just migrate
```

## Module Best Practices

### Keep Modules Focused

Each module should represent a single domain concept:

- ✅ `products` - Product catalog
- ✅ `orders` - Order management
- ✅ `customers` - Customer profiles
- ❌ `products_and_orders` - Too broad

### Use Dependency Injection

Always use `Annotated[X, Depends()]` for dependencies:

```python
# ✅ Good
async def create_product(
    service: Annotated[ProductService, Depends()],
):
    ...

# ❌ Bad
async def create_product():
    service = ProductService()  # Hard to test!
```

### Handle Errors in Services

Raise `HTTPException` in services, not routes:

```python
# ✅ Good - in service
async def get(self, product_id: UUID) -> Product:
    product = await self.repo.get(product_id)
    if not product:
        raise HTTPException(status_code=404, detail="Not found")
    return product

# ❌ Bad - error handling in route
@router.get("/{id}")
async def get_product(id: UUID, repo: Annotated[ProductRepository, Depends()]):
    product = await repo.get(id)
    if not product:
        raise HTTPException(...)  # Business logic leaked to route
```

### Cross-Module Communication

Modules can import each other's services (not repos or models directly):

```python
# orders/services.py
from app.modules.products.services import ProductService

class OrderService:
    def __init__(
        self,
        order_repo: Annotated[OrderRepository, Depends()],
        product_service: Annotated[ProductService, Depends()],
    ):
        self.order_repo = order_repo
        self.product_service = product_service

    async def create_order(self, items: list[OrderItem]) -> Order:
        # Validate products exist via product service
        for item in items:
            await self.product_service.get(item.product_id, tenant_id)
        ...
```

## Module Checklist

When creating a new module, verify:

- [ ] All files created (`__init__`, `models`, `schemas`, `repos`, `services`, `routes`)
- [ ] Model uses appropriate mixins (`UUIDMixin`, `TimestampMixin`, `TenantMixin`)
- [ ] Schemas have `model_config = ConfigDict(from_attributes=True)`
- [ ] Repository filters by `tenant_id`
- [ ] Service handles business logic and errors
- [ ] Routes have `response_model`, `summary`, `tags`
- [ ] Module registered in `api/router.py`
- [ ] Migration created and applied
- [ ] Tests written for service and routes

## Next Steps

- [API Overview](../api/overview.md) - API design standards
- [Authentication](../api/authentication.md) - Protecting endpoints
- [Error Handling](../api/errors.md) - RFC 7807 errors

