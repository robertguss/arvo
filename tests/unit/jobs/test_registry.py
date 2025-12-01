"""Unit tests for jobs registry."""

from datetime import datetime, timedelta
from unittest.mock import AsyncMock, patch

import pytest

from app.core.jobs.registry import (
    ArqPoolHolder,
    close_arq_pool,
    enqueue,
    get_arq_pool,
    init_arq_pool,
)


@pytest.fixture(autouse=True)
def reset_arq_pool():
    """Reset ARQ pool holder before each test."""
    ArqPoolHolder.pool = None
    yield
    ArqPoolHolder.pool = None


class TestInitArqPool:
    """Tests for init_arq_pool function."""

    @pytest.mark.asyncio
    async def test_init_creates_pool_first_time(self):
        """Verify pool is created on first init."""
        mock_pool = AsyncMock()

        with patch(
            "app.core.jobs.registry.create_pool", new_callable=AsyncMock
        ) as mock_create:
            mock_create.return_value = mock_pool

            result = await init_arq_pool()

            assert result is mock_pool
            assert ArqPoolHolder.pool is mock_pool
            mock_create.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_init_returns_existing_pool(self):
        """Verify same pool is returned if already initialized."""
        existing_pool = AsyncMock()
        ArqPoolHolder.pool = existing_pool

        with patch(
            "app.core.jobs.registry.create_pool", new_callable=AsyncMock
        ) as mock_create:
            result = await init_arq_pool()

            assert result is existing_pool
            mock_create.assert_not_awaited()


class TestGetArqPool:
    """Tests for get_arq_pool function."""

    @pytest.mark.asyncio
    async def test_get_pool_returns_initialized_pool(self):
        """Verify pool is returned when initialized."""
        mock_pool = AsyncMock()
        ArqPoolHolder.pool = mock_pool

        result = await get_arq_pool()

        assert result is mock_pool

    @pytest.mark.asyncio
    async def test_get_pool_raises_when_not_initialized(self):
        """Verify RuntimeError when pool not initialized."""
        ArqPoolHolder.pool = None

        with pytest.raises(RuntimeError) as exc_info:
            await get_arq_pool()

        assert "ARQ pool not initialized" in str(exc_info.value)


class TestCloseArqPool:
    """Tests for close_arq_pool function."""

    @pytest.mark.asyncio
    async def test_close_pool_when_initialized(self):
        """Verify pool is closed and cleared."""
        mock_pool = AsyncMock()
        ArqPoolHolder.pool = mock_pool

        await close_arq_pool()

        mock_pool.close.assert_awaited_once()
        assert ArqPoolHolder.pool is None

    @pytest.mark.asyncio
    async def test_close_pool_when_not_initialized(self):
        """Verify no error when pool not initialized."""
        ArqPoolHolder.pool = None

        await close_arq_pool()  # Should not raise

        assert ArqPoolHolder.pool is None


class TestEnqueue:
    """Tests for enqueue function."""

    @pytest.mark.asyncio
    async def test_enqueue_simple_job(self):
        """Verify simple job is enqueued correctly."""
        mock_pool = AsyncMock()
        mock_job = AsyncMock()
        mock_pool.enqueue_job.return_value = mock_job
        ArqPoolHolder.pool = mock_pool

        result = await enqueue("send_email", to="user@example.com")

        assert result is mock_job
        mock_pool.enqueue_job.assert_awaited_once_with(
            "send_email",
            _defer_by=None,
            _defer_until=None,
            _job_id=None,
            _queue_name=None,
            to="user@example.com",
        )

    @pytest.mark.asyncio
    async def test_enqueue_with_positional_args(self):
        """Verify job with positional args is enqueued correctly."""
        mock_pool = AsyncMock()
        mock_job = AsyncMock()
        mock_pool.enqueue_job.return_value = mock_job
        ArqPoolHolder.pool = mock_pool

        await enqueue("process_data", "arg1", "arg2", key="value")

        mock_pool.enqueue_job.assert_awaited_once()
        call_args = mock_pool.enqueue_job.call_args
        assert call_args[0] == ("process_data", "arg1", "arg2")
        assert call_args[1]["key"] == "value"

    @pytest.mark.asyncio
    async def test_enqueue_with_defer_by(self):
        """Verify deferred job is enqueued with correct delay."""
        mock_pool = AsyncMock()
        ArqPoolHolder.pool = mock_pool
        defer_duration = timedelta(hours=1)

        await enqueue("send_reminder", user_id=123, _defer_by=defer_duration)

        call_args = mock_pool.enqueue_job.call_args
        assert call_args[1]["_defer_by"] == defer_duration

    @pytest.mark.asyncio
    async def test_enqueue_with_defer_until(self):
        """Verify job with specific execution time is enqueued correctly."""
        mock_pool = AsyncMock()
        ArqPoolHolder.pool = mock_pool
        exec_time = datetime(2024, 12, 25, 10, 0, 0)

        await enqueue("send_holiday_greeting", _defer_until=exec_time)

        call_args = mock_pool.enqueue_job.call_args
        assert call_args[1]["_defer_until"] == exec_time

    @pytest.mark.asyncio
    async def test_enqueue_with_custom_job_id(self):
        """Verify job with custom ID is enqueued correctly."""
        mock_pool = AsyncMock()
        ArqPoolHolder.pool = mock_pool

        await enqueue("sync_user", user_id=456, _job_id="sync-user-456")

        call_args = mock_pool.enqueue_job.call_args
        assert call_args[1]["_job_id"] == "sync-user-456"

    @pytest.mark.asyncio
    async def test_enqueue_with_custom_queue(self):
        """Verify job is routed to custom queue."""
        mock_pool = AsyncMock()
        ArqPoolHolder.pool = mock_pool

        await enqueue("high_priority_task", _queue_name="priority")

        call_args = mock_pool.enqueue_job.call_args
        assert call_args[1]["_queue_name"] == "priority"

    @pytest.mark.asyncio
    async def test_enqueue_raises_when_pool_not_initialized(self):
        """Verify RuntimeError when pool not initialized."""
        ArqPoolHolder.pool = None

        with pytest.raises(RuntimeError) as exc_info:
            await enqueue("some_job")

        assert "ARQ pool not initialized" in str(exc_info.value)
