"""Shared utilities for job infrastructure.

Provides common functionality used by both the worker and registry modules.
"""

from arq.connections import RedisSettings

from app.config import settings


def get_redis_settings() -> RedisSettings:
    """Get Redis settings for ARQ from app configuration.

    Parses the redis_url from settings and returns an ARQ RedisSettings
    instance suitable for both the worker and connection pool.

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
        # Remove path if present (e.g., redis://host:6379/0)
        port_str = port_str.partition("/")[0]
        port = int(port_str) if port_str else 6379
    else:
        host = host_port.partition("/")[0]
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
