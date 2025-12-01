# Performance Optimization Implementation Guide

This document provides ready-to-use code snippets for the 7 critical Phase 2 fixes identified in `PERFORMANCE_ANALYSIS.md`.

---

## Fix #1: Change Eager Loading to Lazy Loading

**File:** `src/app/modules/users/models.py`

**Current Code (Lines 70-79):**
```python
tenant: Mapped["Tenant"] = relationship(
    "Tenant",
    lazy="selectin",
)
roles: Mapped[list["Role"]] = relationship(
    "Role",
    secondary="user_roles",
    back_populates="users",
    lazy="selectin",
)
```

**Replacement:**
```python
tenant: Mapped["Tenant"] = relationship(
    "Tenant",
    lazy="raise",  # Force explicit loading
    foreign_keys=[tenant_id],
)
roles: Mapped[list["Role"]] = relationship(
    "Role",
    secondary="user_roles",
    back_populates="users",
    lazy="raise",  # Force explicit loading
)
```

**Why:** `lazy="raise"` will raise an error if you try to access an unloaded relationship, forcing you to explicitly load only what you need. This prevents the silent N+1 query problem.

**Testing:** After this change, any code accessing `user.roles` outside an explicit load will raise `sqlalchemy.exc.DetachedInstanceError`, highlighting where you need to add explicit loading.

---

## Fix #2: Create User Auth Projection

**File:** `src/app/modules/users/schemas.py` (add new schema)

```python
from pydantic import BaseModel
from uuid import UUID

class UserAuthProjection(BaseModel):
    """Lightweight user projection for authentication.

    Contains only fields needed for auth checks, avoiding
    loading heavy relationships.
    """
    id: UUID
    tenant_id: UUID
    email: str
    is_active: bool
    is_superuser: bool

    model_config = ConfigDict(from_attributes=True)
```

**File:** `src/app/modules/users/repos.py` (add new method)

```python
async def get_by_id_auth_projection(self, user_id: UUID) -> UserAuthProjection | None:
    """Get user with only auth-required fields.

    Returns a lightweight projection suitable for authentication checks.
    Avoids loading relationships.

    Args:
        user_id: The user's UUID

    Returns:
        UserAuthProjection if found, None otherwise
    """
    stmt = select(
        User.id,
        User.tenant_id,
        User.email,
        User.is_active,
        User.is_superuser
    ).where(User.id == user_id)

    result = await self.session.execute(stmt)
    row = result.first()

    if row:
        return UserAuthProjection(
            id=row[0],
            tenant_id=row[1],
            email=row[2],
            is_active=row[3],
            is_superuser=row[4],
        )
    return None
```

**File:** `src/app/core/auth/dependencies.py` (update get_current_user)

```python
async def get_current_user(
    token_data: Annotated[TokenData, Depends(get_token_data)],
    db: DBSession,
) -> Any:
    """Get the currently authenticated user.

    Uses lightweight projection for performance.
    Full user object loaded on-demand when needed.
    """
    from app.modules.users.repos import UserRepository
    from app.modules.users.schemas import UserAuthProjection

    repo = UserRepository(db)
    # Use projection instead of full user load
    user_proj = await repo.get_by_id_auth_projection(token_data.user_id)

    if not user_proj:
        raise UnauthorizedError(
            "User not found",
            error_code="user_not_found",
        )

    if not user_proj.is_active:
        raise ForbiddenError(
            "User account is deactivated",
            error_code="user_inactive",
        )

    # For endpoints that need full user data, they must explicitly load
    # For most endpoints, they only need id, tenant_id, is_superuser
    return user_proj
```

**Impact:** Reduces per-request query from 3 (user + tenant selectin + roles selectin) to 1 (user columns only). Typical request saves 30-50ms.

---

## Fix #3: Add Database Indexes

**File:** `src/app/modules/users/models.py` (modify User class)

```python
from sqlalchemy import Index

class User(Base, UUIDMixin, TimestampMixin, TenantMixin):
    """User model representing an authenticated user."""

    __tablename__ = "users"

    # ... existing fields ...

    # Add at the end of the class definition:
    __table_args__ = (
        Index("idx_user_email_tenant", "email", "tenant_id"),
        Index("idx_user_oauth", "oauth_provider", "oauth_id"),
    )
```

**File:** `src/app/modules/users/models.py` (modify RefreshToken class)

```python
class RefreshToken(Base, UUIDMixin, TimestampMixin):
    """Refresh token for JWT authentication."""

    __tablename__ = "refresh_tokens"

    # ... existing fields ...

    # Add at the end of the class definition:
    __table_args__ = (
        Index("idx_refresh_token_user_revoked", "user_id", "revoked"),
        Index("idx_refresh_token_expires", "expires_at"),
    )
```

**Database Migration:** Run this to create the indexes

```bash
just migration "add performance indexes"
```

The migration will auto-detect and create these indexes.

---

## Fix #4: Increase Connection Pool Sizing

**File:** `src/app/config.py` (lines 29-30)

**Current:**
```python
database_pool_size: int = 5
database_max_overflow: int = 10
```

**Updated:**
```python
database_pool_size: int = 25          # Increased from 5
database_max_overflow: int = 50       # Increased from 10
```

**Justification:**
- With 100ms average request time and 1000 req/sec, need ~100 concurrent connections
- With N+1 fixes reducing to 20ms, need ~20 concurrent connections
- 25 + 50 = 75 max, safely covers all scenarios
- For larger deployments, increase further based on monitoring

---

## Fix #5: Store OAuth State in Database

**File:** `src/app/modules/auth/models.py` (new file or add to existing)

```python
from datetime import datetime, timedelta, UTC
from uuid import UUID, uuid4

from sqlalchemy import DateTime, ForeignKey, String, Index
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database.base import Base, UUIDMixin

class OAuthState(Base, UUIDMixin):
    """OAuth authorization state for CSRF protection.

    Stores temporary state values used in OAuth flows to prevent
    CSRF attacks. States are one-time use and expire after 10 minutes.
    """

    __tablename__ = "oauth_states"

    state: Mapped[str] = mapped_column(
        String(255),
        unique=True,
        nullable=False,
        index=True,
    )
    provider: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
    )
    user_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(UTC),
        nullable=False,
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(UTC) + timedelta(minutes=10),
        nullable=False,
    )

    __table_args__ = (
        Index("idx_oauth_state_expires", "expires_at"),
        Index("idx_oauth_state_provider", "provider"),
    )
```

**File:** `src/app/core/auth/oauth.py` (add methods to OAuthProvider or create service)

```python
from app.modules.auth.models import OAuthState
from app.api.dependencies import DBSession
from typing import Annotated
from uuid import UUID

class OAuthStateService:
    """Service for managing OAuth state values."""

    def __init__(self, db: DBSession) -> None:
        self.db = db

    async def create_state(self, provider: str, user_id: UUID | None = None) -> str:
        """Create a new OAuth state.

        Args:
            provider: OAuth provider name
            user_id: Optional user ID if already authenticated

        Returns:
            State value for OAuth redirect
        """
        state = secrets.token_urlsafe(32)

        oauth_state = OAuthState(
            state=state,
            provider=provider,
            user_id=user_id,
        )
        self.db.add(oauth_state)
        await self.db.flush()

        return state

    async def validate_and_consume_state(
        self,
        state: str,
        provider: str,
    ) -> bool:
        """Validate and consume an OAuth state (one-time use).

        Args:
            state: State value to validate
            provider: Expected provider

        Returns:
            True if state is valid, False otherwise
        """
        stmt = select(OAuthState).where(
            OAuthState.state == state,
            OAuthState.provider == provider,
            OAuthState.expires_at > datetime.now(UTC),
        )
        result = await self.db.execute(stmt)
        oauth_state = result.scalar_one_or_none()

        if oauth_state:
            # Consume the state (one-time use)
            await self.db.delete(oauth_state)
            await self.db.flush()
            return True

        return False

    async def cleanup_expired(self) -> int:
        """Clean up expired states.

        Call periodically (e.g., daily via background job in Phase 3).

        Returns:
            Number of states deleted
        """
        stmt = select(OAuthState).where(
            OAuthState.expires_at < datetime.now(UTC)
        )
        result = await self.db.execute(stmt)
        expired = result.scalars().all()

        for state in expired:
            await self.db.delete(state)

        await self.db.flush()
        return len(expired)


# Type alias for dependency injection
OAuthStateSvc = Annotated[OAuthStateService, Depends(OAuthStateService)]
```

**Usage in OAuth routes:**

```python
@router.get("/auth/oauth/{provider}/authorize")
async def oauth_authorize(
    provider: str,
    redirect_uri: str,
    oauth_service: OAuthStateSvc,
):
    """Redirect to OAuth provider."""
    provider_obj = get_provider(provider)
    if not provider_obj:
        raise HTTPException(status_code=400, detail="Provider not configured")

    # Create and store state
    state = await oauth_service.create_state(provider)

    # Redirect to provider
    auth_url = provider_obj.get_authorize_url(redirect_uri, state)
    return RedirectResponse(url=auth_url)


@router.get("/auth/oauth/{provider}/callback")
async def oauth_callback(
    provider: str,
    code: str,
    state: str,
    oauth_service: OAuthStateSvc,
    auth_service: AuthSvc,
):
    """Handle OAuth provider callback."""
    # Validate state
    if not await oauth_service.validate_and_consume_state(state, provider):
        raise HTTPException(status_code=400, detail="Invalid state")

    # Continue with token exchange...
    # ...
```

---

## Fix #6: Remove Duplicate Token Decoding

**File:** `src/app/core/auth/middleware.py` (update TenantContextMiddleware)

```python
async def dispatch(
    self,
    request: Request,
    call_next: Callable[[Request], Any],
) -> Response:
    """Process the request and inject tenant context.

    Stores decoded token in request.state to avoid
    duplicate decoding in dependencies.
    """
    # Skip for excluded paths
    if any(request.url.path.startswith(path) for path in self.exclude_paths):
        return await call_next(request)

    # Try to extract token from Authorization header
    auth_header = request.headers.get("Authorization")
    if auth_header and auth_header.startswith("Bearer "):
        token = auth_header.split(" ", 1)[1]
        token_data = decode_token(token)

        if token_data:
            # Store decoded token for later use
            request.state.token_data = token_data
            request.state.tenant_id = token_data.tenant_id
            request.state.user_id = token_data.user_id

            # Bind to structlog context
            structlog.contextvars.bind_contextvars(
                tenant_id=str(token_data.tenant_id),
                user_id=str(token_data.user_id),
            )

    return await call_next(request)
```

**File:** `src/app/core/auth/dependencies.py` (update get_token_data)

```python
async def get_token_data(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)] = None,
) -> TokenData:
    """Extract and validate token data.

    Reuses token decoded in middleware if available,
    avoiding duplicate decoding.
    """
    # Try to get from middleware first (already decoded)
    if hasattr(request.state, "token_data"):
        return request.state.token_data

    # Fallback to decoding (for contexts where middleware didn't run)
    if not credentials:
        raise UnauthorizedError(
            "Missing authentication token",
            error_code="missing_token",
        )

    token_data = decode_token(credentials.credentials)
    if not token_data:
        raise UnauthorizedError(
            "Invalid or expired token",
            error_code="invalid_token",
        )

    if token_data.type != "access":
        raise UnauthorizedError(
            "Invalid token type",
            error_code="invalid_token_type",
        )

    # Cache in state for potential reuse
    request.state.token_data = token_data
    return token_data
```

---

## Fix #7: Fix Middleware Ordering

**File:** `src/app/main.py` (update create_app function)

**Current Code (Lines 80-96):**
```python
# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if settings.is_development else [],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Add request ID middleware (outermost, runs first)
app.add_middleware(RequestIdMiddleware)

# Add tenant context middleware
app.add_middleware(TenantContextMiddleware)

# Add request logging middleware
app.add_middleware(RequestLoggingMiddleware)
```

**Replacement:**
```python
# IMPORTANT: Middleware added later executes first (lifo stack)
# So add in reverse order of desired execution

# Innermost: Request logging (last to execute, closest to handler)
app.add_middleware(RequestLoggingMiddleware)

# Middle: Tenant context extraction
app.add_middleware(TenantContextMiddleware)

# Near outer: Request ID injection
app.add_middleware(RequestIdMiddleware)

# Outermost: CORS handling (first to execute)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if settings.is_development else [],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

**Execution Order After Fix:**
1. CORSMiddleware (handles CORS first)
2. RequestIdMiddleware (adds request ID early)
3. TenantContextMiddleware (extracts tenant/user context)
4. RequestLoggingMiddleware (logs with all context available)
5. Route handler

**Benefit:** Request logging now has access to tenant_id and user_id from request.state, enabling accurate contextual logging.

---

## Implementation Checklist

Use this checklist to track implementation of all fixes:

```markdown
Phase 2 Performance Fixes Implementation Checklist
==================================================

Critical (Blocks Production)
----------------------------
[ ] Fix #1: Lazy loading (models.py) - 15 min
[ ] Fix #2: User auth projection (schemas.py + repos.py + dependencies.py) - 45 min
[ ] Fix #3: Database indexes (models.py + migration) - 20 min
[ ] Fix #4: Connection pool sizing (config.py) - 5 min
[ ] Fix #5: OAuth state storage (new model + service) - 90 min
[ ] Fix #6: Remove duplicate token decoding (middleware.py + dependencies.py) - 30 min
[ ] Fix #7: Middleware ordering (main.py) - 5 min

Total Estimated Time: 4.5 hours
=================================

Testing After Implementation
----------------------------
[ ] Run unit tests: just test-unit
[ ] Run integration tests: just test-integration
[ ] Performance test: Load test with 1000 req/sec
[ ] Check migrations apply cleanly: just migrate
[ ] Verify lazy loading raises on access: test accessing user.roles without load
[ ] Verify auth speed improves: profile /api/v1/users/me endpoint
[ ] Verify OAuth flow works end-to-end
[ ] Verify logging includes tenant_id (check logs)

Post-Deployment Monitoring
---------------------------
[ ] Monitor query count per request (should be 1-2 for list endpoints)
[ ] Monitor request latency (should drop 50%+)
[ ] Monitor database connection pool utilization
[ ] Monitor for DetachedInstanceError in logs (indicates N+1 access)
[ ] Check OAuth state table doesn't grow unbounded

Migration Safety
----------------
[ ] Backup production database before migration
[ ] Test migration on staging environment first
[ ] Have rollback plan (migrations are reversible)
[ ] Monitor for migration errors in application logs
```

---

## Performance Verification After Implementation

### Before/After Metrics

Use these queries to measure improvement:

```sql
-- Check database index creation
SELECT schemaname, tablename, indexname
FROM pg_indexes
WHERE tablename IN ('users', 'refresh_tokens')
ORDER BY indexname;

-- Monitor connection pool usage (on running server)
-- Check config.database_pool_size = 25 and max_overflow = 50
```

### Load Testing Script

```python
import asyncio
import httpx
import time
from statistics import mean, stdev

async def load_test(num_requests=1000, concurrency=10):
    """Simple load test to verify improvements."""

    async with httpx.AsyncClient() as client:
        token = "your_test_token_here"
        headers = {"Authorization": f"Bearer {token}"}

        start = time.perf_counter()

        async def make_request():
            try:
                return await client.get(
                    "http://localhost:8000/api/v1/users/me",
                    headers=headers,
                    timeout=10.0
                )
            except Exception as e:
                return None

        # Run requests concurrently
        tasks = [make_request() for _ in range(num_requests)]
        results = []

        for i in range(0, num_requests, concurrency):
            batch = tasks[i:i+concurrency]
            results.extend(await asyncio.gather(*batch))

        elapsed = time.perf_counter() - start
        successful = sum(1 for r in results if r and r.status_code == 200)

        print(f"Results:")
        print(f"  Total requests: {num_requests}")
        print(f"  Successful: {successful}")
        print(f"  Failed: {num_requests - successful}")
        print(f"  Duration: {elapsed:.2f}s")
        print(f"  Throughput: {num_requests/elapsed:.0f} req/sec")

# Run: asyncio.run(load_test(1000, 10))
```

Expected improvements with fixes:
- **Latency:** 100ms → 20-30ms (70% reduction)
- **Throughput:** 100 req/sec → 500+ req/sec (5x improvement)
- **Database queries:** 4 per request → 1 per request (75% reduction)

---

## Reverting Changes (If Needed)

Each fix is independently reversible:

1. **Lazy loading:** Change back to `lazy="selectin"`
2. **Auth projection:** Use full user object in get_current_user
3. **Indexes:** Drop with migration `just migration "remove performance indexes"`
4. **Connection pool:** Revert config values
5. **OAuth state:** Remove OAuthState model, use in-memory dict again
6. **Token decoding:** Remove from middleware, rely only on dependency
7. **Middleware order:** Add middleware in original order

---

## Next Steps (Phase 3)

After Phase 2 is stable, Phase 3 will add:

1. Redis caching layer with `@cached` decorator
2. User auth projection caching (5-minute TTL)
3. Tenant data caching (1-hour TTL)
4. Role assignment caching (15-minute TTL)
5. Window function optimization for count queries
6. Expected improvement: 50-100x faster for cached endpoints

For now, these fixes provide 5-10x improvement without requiring external services.

