"""Observability module for tracing and metrics.

Provides OpenTelemetry integration for distributed tracing.
"""

from app.core.observability.tracing import setup_tracing


__all__ = ["setup_tracing"]
