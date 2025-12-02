"""Pytest configuration and shared fixtures."""

import asyncio
from collections.abc import AsyncGenerator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import NullPool

from app.config import settings
from app.core.audit.models import AuditLog  # noqa: F401
from app.core.database import Base, get_db
from app.core.permissions.models import Permission, Role, UserRole  # noqa: F401
from app.main import create_app

# Import all models to ensure they're registered with Base.metadata
from app.modules.tenants.models import Tenant
from app.modules.users.models import RefreshToken, RevokedToken, User  # noqa: F401
from tests.factories.tenant import TenantFactory
from tests.factories.user import UserFactory


# Test database URL - uses same DB with _test suffix
TEST_DATABASE_URL = settings.async_database_url.replace(
    "/agency_standard", "/agency_standard_test"
)


@pytest.fixture(scope="session")
def event_loop():
    """Create an instance of the default event loop for the test session."""
    loop = asyncio.get_event_loop_policy().new_event_loop()
    yield loop
    loop.close()


@pytest.fixture(scope="function")
async def engine():
    """Create test database engine."""
    engine = create_async_engine(
        TEST_DATABASE_URL,
        poolclass=NullPool,
        echo=False,
    )

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    yield engine

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)

    await engine.dispose()


@pytest.fixture
async def db(engine) -> AsyncGenerator[AsyncSession, None]:
    """Provide a transactional database session for tests.

    Each test runs in its own transaction that is rolled back
    after the test completes, ensuring test isolation.
    """
    async_session_factory = sessionmaker(
        bind=engine,
        class_=AsyncSession,
        expire_on_commit=False,
        autoflush=False,
    )

    async with engine.connect() as conn:
        await conn.begin()

        async with async_session_factory(bind=conn) as session:
            yield session

        await conn.rollback()


@pytest.fixture
async def app(db: AsyncSession):
    """Create test application instance."""
    application = create_app()

    # Override database dependency
    async def override_get_db() -> AsyncGenerator[AsyncSession, None]:
        yield db

    application.dependency_overrides[get_db] = override_get_db

    yield application

    application.dependency_overrides.clear()


@pytest.fixture
async def client(app) -> AsyncGenerator[AsyncClient, None]:
    """Provide async HTTP client for API testing."""
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        yield client


@pytest.fixture
def anyio_backend() -> str:
    """Specify the async backend for anyio."""
    return "asyncio"


# ============================================================
# Tenant and User Fixtures
# ============================================================


@pytest.fixture
async def tenant(db: AsyncSession) -> Tenant:
    """Create a test tenant.

    Returns:
        A persisted Tenant instance
    """
    tenant = TenantFactory.build()
    db.add(tenant)
    await db.flush()
    return tenant


@pytest.fixture
async def user(db: AsyncSession, tenant: Tenant) -> User:
    """Create a test user linked to a tenant.

    Args:
        db: Database session
        tenant: The test tenant

    Returns:
        A persisted User instance
    """
    user = UserFactory.build(tenant_id=tenant.id)
    db.add(user)
    await db.flush()
    return user


@pytest.fixture
def auth_headers(user: User, tenant: Tenant) -> dict[str, str]:
    """Generate authorization headers with a valid JWT token.

    Args:
        user: The test user
        tenant: The test tenant

    Returns:
        Dictionary with Authorization header
    """
    # Import here to avoid circular import at module load time
    from app.core.auth.backend import create_access_token

    token = create_access_token(user_id=user.id, tenant_id=tenant.id)
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
async def authenticated_client(
    app, auth_headers: dict[str, str]
) -> AsyncGenerator[AsyncClient, None]:
    """Provide an authenticated async HTTP client for API testing.

    This client includes a valid JWT token for the test user.

    Args:
        app: The FastAPI application
        auth_headers: Authorization headers with JWT token

    Yields:
        AsyncClient with authentication headers
    """
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
        headers=auth_headers,
    ) as client:
        yield client
