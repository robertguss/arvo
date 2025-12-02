"""Integration tests for ARQ worker and job execution."""

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.jobs.tasks.cleanup import cleanup_expired_tokens
from app.modules.tenants.models import Tenant
from app.modules.users.models import RefreshToken, RevokedToken, User


@pytest.mark.asyncio
async def test_cleanup_expired_tokens_removes_expired_refresh_tokens(db: AsyncSession):
    """Test that cleanup job removes expired refresh tokens."""
    # Create a tenant and user directly (avoiding factory relationship issues)
    tenant = Tenant(
        name="Test Tenant",
        slug=f"test-tenant-{uuid4().hex[:8]}",
        is_active=True,
    )
    db.add(tenant)
    await db.flush()

    user = User(
        email=f"test-{uuid4().hex[:8]}@example.com",
        password_hash="$2b$12$dummy",
        full_name="Test User",
        tenant_id=tenant.id,
        is_active=True,
    )
    db.add(user)
    await db.flush()

    # Create expired and valid refresh tokens
    expired_token = RefreshToken(
        user_id=user.id,
        token_hash="expired_hash_" + uuid4().hex[:32],
        expires_at=datetime.now(UTC) - timedelta(days=1),
        revoked=False,
    )
    valid_token = RefreshToken(
        user_id=user.id,
        token_hash="valid_hash_" + uuid4().hex[:32],
        expires_at=datetime.now(UTC) + timedelta(days=7),
        revoked=False,
    )

    db.add(expired_token)
    db.add(valid_token)
    await db.flush()

    # Create a mock context with session factory
    async def session_factory():
        return db

    ctx = {"db_session_factory": lambda: session_factory()}

    # Mock the async context manager behavior
    class MockSessionFactory:
        async def __aenter__(self):
            return db

        async def __aexit__(self, *args):
            pass

    ctx["db_session_factory"] = lambda: MockSessionFactory()

    # Run the cleanup task
    result = await cleanup_expired_tokens(ctx)

    # Verify results
    assert result["refresh_tokens_deleted"] >= 1

    # Verify expired token is gone but valid token remains
    await db.refresh(valid_token)
    result = await db.execute(
        select(RefreshToken).where(RefreshToken.id == expired_token.id)
    )
    assert result.scalar_one_or_none() is None


@pytest.mark.asyncio
async def test_cleanup_expired_tokens_removes_expired_revoked_tokens(db: AsyncSession):
    """Test that cleanup job removes expired revoked tokens."""
    # Create expired and valid revoked tokens
    expired_revoked = RevokedToken(
        jti="expired_jti_" + uuid4().hex[:32],
        expires_at=datetime.now(UTC) - timedelta(hours=1),
    )
    valid_revoked = RevokedToken(
        jti="valid_jti_" + uuid4().hex[:32],
        expires_at=datetime.now(UTC) + timedelta(hours=1),
    )

    db.add(expired_revoked)
    db.add(valid_revoked)
    await db.flush()

    # Create mock context
    class MockSessionFactory:
        async def __aenter__(self):
            return db

        async def __aexit__(self, *args):
            pass

    ctx = {"db_session_factory": lambda: MockSessionFactory()}

    # Run the cleanup task
    result = await cleanup_expired_tokens(ctx)

    # Verify results
    assert result["revoked_tokens_deleted"] >= 1

    # Verify expired token is gone but valid token remains
    await db.refresh(valid_revoked)
    result_query = await db.execute(
        select(RevokedToken).where(RevokedToken.id == expired_revoked.id)
    )
    assert result_query.scalar_one_or_none() is None
