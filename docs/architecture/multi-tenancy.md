# Multi-Tenancy

The Agency Standard uses **row-level tenant isolation**. Every tenant's data lives in the same tables but is automatically filtered by `tenant_id`.

## Why Row-Level Isolation?

| Approach                   | Pros                           | Cons                            |
| -------------------------- | ------------------------------ | ------------------------------- |
| **Separate Databases**     | Complete isolation             | Complex migrations, high cost   |
| **Separate Schemas**       | Good isolation                 | Migration complexity            |
| **Row-Level (our choice)** | Simple migrations, scales well | Requires careful query handling |

Row-level isolation is the right choice for most SaaS applications:

- ✅ Single schema to manage
- ✅ Scales to thousands of tenants
- ✅ Easy cross-tenant admin features
- ✅ Lower infrastructure costs

## How It Works

### 1. Tenant Mixin

All tenant-scoped models inherit from `TenantMixin`:

```python
from app.core.database import Base, TenantMixin, UUIDMixin, TimestampMixin

class Item(Base, UUIDMixin, TimestampMixin, TenantMixin):
    __tablename__ = "items"
    name: Mapped[str] = mapped_column(String(255))
```

This adds a `tenant_id` column with a foreign key to the `tenants` table:

```python
class TenantMixin:
    tenant_id: Mapped[UUID] = mapped_column(
        ForeignKey("tenants.id", ondelete="CASCADE"),
        index=True,
        nullable=False,
    )
```

### 2. Tenant Context Middleware

Every authenticated request has tenant context injected by middleware:

```python
class TenantContextMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # Extract tenant from authenticated user
        if hasattr(request.state, "user") and request.state.user:
            request.state.tenant_id = request.state.user.tenant_id

        return await call_next(request)
```

### 3. Scoped Queries

Repositories filter queries by the current tenant:

```python
class ItemRepository:
    async def list(self, tenant_id: UUID) -> list[Item]:
        result = await self.session.execute(
            select(Item)
            .where(Item.tenant_id == tenant_id)  # Always filter by tenant
            .order_by(Item.created_at.desc())
        )
        return list(result.scalars().all())
```

## Tenant Context Flow

```
┌─────────────────────────────────────────────────────────┐
│                    HTTP Request                          │
│              Authorization: Bearer <jwt>                 │
└────────────────────────┬────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│              Auth Middleware                             │
│     - Validates JWT                                      │
│     - Sets request.state.user                            │
└────────────────────────┬────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│           Tenant Context Middleware                      │
│     - Extracts user.tenant_id                            │
│     - Sets request.state.tenant_id                       │
└────────────────────────┬────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│              Route Handler                               │
│     - Passes tenant_id to service                        │
└────────────────────────┬────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│              Repository                                  │
│     - All queries include tenant_id filter               │
└─────────────────────────────────────────────────────────┘
```

## Tenant Model

```python
# src/app/modules/tenants/models.py
class Tenant(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "tenants"

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    slug: Mapped[str] = mapped_column(String(100), unique=True, nullable=False)
    is_active: Mapped[bool] = mapped_column(default=True)

    # Settings stored as JSONB
    settings: Mapped[dict] = mapped_column(JSONB, default=dict)

    # Relationships
    users: Mapped[list["User"]] = relationship(back_populates="tenant")
```

## Isolation Guarantees

| Scenario                     | Behavior                                 |
| ---------------------------- | ---------------------------------------- |
| Query without tenant context | Must explicitly pass `tenant_id`         |
| Cross-tenant data access     | Impossible via normal repository methods |
| Admin/superuser access       | Use `bypass_tenant=True` parameter       |
| Tenant deletion              | Cascading delete of all tenant data      |

## Best Practices

### Always Pass Tenant ID

```python
# ✅ Good - explicit tenant_id
async def list_items(self, tenant_id: UUID) -> list[Item]:
    return await self.repo.list(tenant_id)

# ❌ Bad - no tenant context
async def list_items(self) -> list[Item]:
    return await self.repo.list()  # Could leak data!
```

### Use the Mixin for New Models

```python
# ✅ Good - tenant-scoped model
class Invoice(Base, UUIDMixin, TimestampMixin, TenantMixin):
    __tablename__ = "invoices"

# ❌ Bad - missing TenantMixin
class Invoice(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "invoices"  # Not tenant-isolated!
```

### Handle Admin Operations Explicitly

```python
class AdminService:
    async def get_all_tenants_data(self) -> list[Item]:
        """Admin-only: returns data across all tenants."""
        # Explicit bypass - requires admin permission check first
        return await self.repo.list_all(bypass_tenant=True)
```

## Database Indexes

The `TenantMixin` automatically adds an index on `tenant_id`:

```sql
CREATE INDEX ix_items_tenant_id ON items (tenant_id);
```

For queries that filter by tenant + another column, add composite indexes:

```python
class Item(Base, UUIDMixin, TimestampMixin, TenantMixin):
    __tablename__ = "items"
    __table_args__ = (
        Index("ix_items_tenant_status", "tenant_id", "status"),
    )
```

## Tenant Deletion

When a tenant is deleted, all associated data is cascade-deleted:

```sql
-- The foreign key with ON DELETE CASCADE handles this
ALTER TABLE items
ADD CONSTRAINT fk_items_tenant
FOREIGN KEY (tenant_id) REFERENCES tenants(id)
ON DELETE CASCADE;
```

!!! warning "Soft Deletes Recommended"
For production, consider soft deletes instead of hard deletes. Add an `is_deleted` flag and filter it out in queries.

## Testing Multi-Tenancy

```python
@pytest.mark.asyncio
async def test_tenant_isolation(db: AsyncSession):
    """Verify data is isolated between tenants."""
    # Create two tenants
    tenant_a = await TenantFactory.create_async(db)
    tenant_b = await TenantFactory.create_async(db)

    # Create item for tenant A
    item = Item(tenant_id=tenant_a.id, name="Secret Item")
    db.add(item)
    await db.flush()

    # Query as tenant B should return nothing
    repo = ItemRepository(db)
    items = await repo.list(tenant_id=tenant_b.id)

    assert len(items) == 0  # Tenant B can't see Tenant A's data
```

## Next Steps

- [Modules](modules.md) - Creating feature modules
- [Authentication](../api/authentication.md) - How users authenticate
- [Permissions](../api/authentication.md#permissions) - Role-based access control
