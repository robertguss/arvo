"""ARQ worker configuration.

Defines the worker settings including registered jobs,
cron schedules, and startup/shutdown hooks.
"""

from typing import Any, ClassVar

import structlog
from arq import cron
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.config import settings
from app.core.jobs.tasks.cleanup import cleanup_expired_tokens
from app.core.jobs.utils import get_redis_settings


async def startup(ctx: dict[str, Any]) -> None:
    """Initialize resources for the worker.

    Called once when the worker starts. Sets up database
    connections and other resources needed by jobs.

    Args:
        ctx: Worker context dict (shared across all jobs)
    """

    log = structlog.get_logger()
    log.info("worker_startup", environment=settings.environment)

    engine = create_async_engine(
        settings.async_database_url,
        pool_size=5,
        max_overflow=10,
        echo=settings.database_echo,
    )

    # Create session factory
    session_factory = async_sessionmaker(
        bind=engine,
        class_=AsyncSession,
        expire_on_commit=False,
        autoflush=False,
    )

    # Store in context for job access
    ctx["db_engine"] = engine
    ctx["db_session_factory"] = session_factory

    log.info("worker_startup_complete")


async def shutdown(ctx: dict[str, Any]) -> None:
    """Cleanup resources when the worker stops.

    Args:
        ctx: Worker context dict
    """
    log = structlog.get_logger()
    log.info("worker_shutdown")

    # Close database engine
    engine = ctx.get("db_engine")
    if engine:
        await engine.dispose()
        log.info("database_engine_disposed")

    log.info("worker_shutdown_complete")


class WorkerSettings:
    """ARQ worker settings.

    Configure this class with all registered job functions,
    cron schedules, and worker parameters.

    Run the worker with:
        arq app.core.jobs.worker.WorkerSettings
    """

    # Registered job functions
    functions: ClassVar[list[Any]] = [
        cleanup_expired_tokens,
    ]

    # Cron jobs (scheduled tasks)
    cron_jobs: ClassVar[list[Any]] = [
        # Clean up expired tokens daily at 3 AM
        cron(cleanup_expired_tokens, hour=3, minute=0),
    ]

    # Worker lifecycle hooks
    on_startup = startup
    on_shutdown = shutdown

    # Redis connection
    redis_settings = get_redis_settings()

    # Worker configuration
    max_jobs = 10  # Maximum concurrent jobs
    job_timeout = 300  # 5 minutes per job
    keep_result = 3600  # Keep results for 1 hour
    retry_jobs = True  # Retry failed jobs
    max_tries = 3  # Maximum retry attempts

