"""OpenTelemetry tracing configuration.

Provides distributed tracing with automatic instrumentation for:
- FastAPI requests
- SQLAlchemy database queries
- Redis operations

Traces are exported to an OTLP-compatible backend (Jaeger, Tempo, etc.)
when OTLP_ENDPOINT is configured.
"""

import structlog
from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter

from app.config import settings


log = structlog.get_logger()


def setup_tracing(app: FastAPI) -> None:
    """Configure OpenTelemetry tracing for the application.

    Sets up distributed tracing with automatic instrumentation for
    FastAPI, SQLAlchemy, and Redis. Exports traces to an OTLP backend
    if configured, otherwise logs to console in debug mode.

    Args:
        app: The FastAPI application instance to instrument
    """
    # Create resource with service information
    resource = Resource.create(
        {
            "service.name": settings.app_name.lower().replace(" ", "-"),
            "service.version": "0.1.0",
            "deployment.environment": settings.environment,
        }
    )

    # Create tracer provider
    provider = TracerProvider(resource=resource)

    # Configure exporter based on environment
    if settings.otlp_endpoint:
        # Production: Export to OTLP backend (Jaeger, Tempo, etc.)
        exporter = OTLPSpanExporter(
            endpoint=settings.otlp_endpoint,
            insecure=not settings.otlp_endpoint.startswith("https"),
        )
        provider.add_span_processor(BatchSpanProcessor(exporter))
        log.info(
            "tracing_configured",
            exporter="otlp",
            endpoint=settings.otlp_endpoint,
        )
    elif settings.debug:
        # Development: Log spans to console
        provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
        log.info("tracing_configured", exporter="console")
    else:
        # No tracing configured
        log.info("tracing_disabled", reason="no OTLP_ENDPOINT configured")
        return

    # Set the global tracer provider
    trace.set_tracer_provider(provider)

    # Instrument FastAPI
    FastAPIInstrumentor.instrument_app(
        app,
        excluded_urls="health/.*,docs,redoc,openapi.json",
    )
    log.debug("instrumented_fastapi")

    # Instrument Redis
    RedisInstrumentor().instrument()
    log.debug("instrumented_redis")

    # Note: SQLAlchemy instrumentation requires the engine
    # It will be set up when the database engine is created
    log.info("tracing_setup_complete")


def instrument_sqlalchemy(engine) -> None:  # type: ignore[no-untyped-def]
    """Instrument SQLAlchemy engine for tracing.

    Should be called after the database engine is created.

    Args:
        engine: The SQLAlchemy engine to instrument
    """
    SQLAlchemyInstrumentor().instrument(engine=engine)
    log.debug("instrumented_sqlalchemy")


def get_tracer(name: str) -> trace.Tracer:
    """Get a tracer instance for manual span creation.

    Args:
        name: Name for the tracer (typically module name)

    Returns:
        OpenTelemetry Tracer instance

    Example:
        tracer = get_tracer(__name__)
        with tracer.start_as_current_span("my_operation"):
            # ... do work
    """
    return trace.get_tracer(name)


def shutdown_tracing() -> None:
    """Shutdown tracing and flush any pending spans.

    Should be called during application shutdown.
    """
    provider = trace.get_tracer_provider()
    if isinstance(provider, TracerProvider):
        provider.shutdown()
        log.info("tracing_shutdown_complete")
