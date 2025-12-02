"""FastAPI application factory."""

import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api import api_router
from app.config import settings
from app.core.auth import RequestIdMiddleware, TenantContextMiddleware
from app.core.cache.redis import close_redis_pool
from app.core.errors import register_exception_handlers
from app.core.jobs.registry import close_arq_pool, init_arq_pool
from app.core.logging import RequestLoggingMiddleware
from app.core.observability import setup_tracing
from app.core.observability.tracing import shutdown_tracing


# Configure structlog
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        (
            structlog.processors.JSONRenderer()
            if settings.is_production
            else structlog.dev.ConsoleRenderer()
        ),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(
        logging.INFO if settings.log_level == "INFO" else logging.DEBUG
    ),
    context_class=dict,
    logger_factory=structlog.PrintLoggerFactory(),
    cache_logger_on_first_use=True,
)

logger = structlog.get_logger()


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncGenerator[None, None]:
    """Application lifespan handler.

    Handles startup and shutdown events.
    """
    # Startup
    logger.info(
        "application_startup",
        app_name=settings.app_name,
        environment=settings.environment,
    )

    # Initialize ARQ pool for background jobs
    try:
        await init_arq_pool()
        logger.info("arq_pool_initialized")
    except Exception as e:
        logger.warning("arq_pool_init_failed", error=str(e))

    yield

    # Shutdown
    logger.info("application_shutdown")

    # Shutdown tracing (flush pending spans)
    shutdown_tracing()
    logger.info("tracing_shutdown")

    # Close ARQ connection pool
    await close_arq_pool()
    logger.info("arq_pool_closed")

    # Close Redis connection pool
    await close_redis_pool()
    logger.info("redis_pool_closed")


def create_app() -> FastAPI:
    """Create and configure the FastAPI application.

    Returns:
        Configured FastAPI application instance.
    """
    app = FastAPI(
        title=settings.app_name,
        description="A production-ready Python backend kit for software agencies",
        version="0.1.0",
        debug=settings.debug,
        lifespan=lifespan,
        # Disable docs in production
        docs_url="/docs" if not settings.is_production else None,
        redoc_url="/redoc" if not settings.is_production else None,
        openapi_url="/openapi.json" if not settings.is_production else None,
    )

    # Configure CORS (P3-2: Use configured origins with sensible defaults)
    cors_origins = settings.cors_origins
    if settings.is_development and not cors_origins:
        cors_origins = ["http://localhost:3000", "http://localhost:5173"]

    app.add_middleware(
        CORSMiddleware,
        allow_origins=cors_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
    )

    # Add request ID middleware (outermost, runs first)
    app.add_middleware(RequestIdMiddleware)

    # Add tenant context middleware
    app.add_middleware(TenantContextMiddleware)

    # Add request logging middleware
    app.add_middleware(RequestLoggingMiddleware)

    # Register exception handlers for RFC 7807 error responses
    register_exception_handlers(app)

    # Include API router
    app.include_router(api_router)

    # Setup OpenTelemetry tracing
    setup_tracing(app)

    return app
