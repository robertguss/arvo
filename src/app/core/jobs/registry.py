"""Job registry and enqueueing utilities.

Provides a centralized way to enqueue background jobs from
anywhere in the application.
"""

from datetime import timedelta
from typing import Any

from arq import ArqRedis, create_pool
from arq.connections import RedisSettings

from app.config import settings


class ArqPoolHolder:
    """Holder for the ARQ connection pool.

    Uses a class attribute to manage module-level state without
    global statements.
    """

    pool: ArqRedis | None = None


def _get_redis_settings() -> RedisSettings:
    """Get Redis settings for ARQ from app configuration.

    Returns:
        ARQ RedisSettings instance
    """
    # Parse redis URL
    url = str(settings.redis_url)
    # Remove redis:// prefix and parse
    if url.startswith("redis://"):
        url = url[8:]

    # Parse host:port
    if "@" in url:
        # Has auth
        auth, host_port = url.split("@", 1)
    else:
        auth = None
        host_port = url

    # Parse host and port
    if ":" in host_port:
        host, port_str = host_port.split(":", 1)
        # Remove path if present
        if "/" in port_str:
            port_str = port_str.split("/", 0)[0]
        port = int(port_str.split("/")[0]) if port_str else 6379
    else:
        host = host_port.split("/")[0]
        port = 6379

    # Parse password if present
    password = None
    if auth and ":" in auth:
        _, password = auth.split(":", 1)

    return RedisSettings(
        host=host,
        port=port,
        password=password,
        database=0,
    )


async def init_arq_pool() -> ArqRedis:
    """Initialize the ARQ connection pool.

    Should be called during application startup.

    Returns:
        ARQ Redis pool
    """
    if ArqPoolHolder.pool is None:
        ArqPoolHolder.pool = await create_pool(_get_redis_settings())
    return ArqPoolHolder.pool


async def get_arq_pool() -> ArqRedis:
    """Get the ARQ connection pool.

    Returns:
        ARQ Redis pool

    Raises:
        RuntimeError: If pool not initialized
    """
    if ArqPoolHolder.pool is None:
        raise RuntimeError(
            "ARQ pool not initialized. Call init_arq_pool() during startup."
        )
    return ArqPoolHolder.pool


async def close_arq_pool() -> None:
    """Close the ARQ connection pool.

    Should be called during application shutdown.
    """
    if ArqPoolHolder.pool is not None:
        await ArqPoolHolder.pool.close()
        ArqPoolHolder.pool = None


async def enqueue(
    job_name: str,
    *args: Any,
    _defer_by: timedelta | None = None,
    _defer_until: Any | None = None,
    _job_id: str | None = None,
    _queue_name: str | None = None,
    **kwargs: Any,
) -> Any:
    """Enqueue a background job.

    Args:
        job_name: Name of the job function to run
        *args: Positional arguments for the job
        _defer_by: Delay execution by this duration
        _defer_until: Execute at this specific time
        _job_id: Custom job ID (for deduplication)
        _queue_name: Custom queue name
        **kwargs: Keyword arguments for the job

    Returns:
        Job instance

    Example:
        await enqueue("send_email", to="user@example.com", subject="Welcome!")
        await enqueue("send_reminder", user_id=user.id, _defer_by=timedelta(hours=24))
    """
    pool = await get_arq_pool()
    return await pool.enqueue_job(
        job_name,
        *args,
        _defer_by=_defer_by,
        _defer_until=_defer_until,
        _job_id=_job_id,
        _queue_name=_queue_name,
        **kwargs,
    )
