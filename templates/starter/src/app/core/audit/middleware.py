"""Automatic audit capture via SQLAlchemy event listeners.

Provides automatic tracking of model changes for models that
inherit from AuditMixin.
"""

from contextvars import ContextVar
from datetime import date, datetime
from decimal import Decimal
from enum import Enum
from typing import Any
from uuid import UUID

import structlog
from sqlalchemy import event, inspect
from sqlalchemy.orm import Session

from app.core.audit.models import AuditLog


log = structlog.get_logger()


# ContextVar for async-safe audit context storage
# Each async task/request gets its own isolated context
_audit_context: ContextVar[dict[str, Any] | None] = ContextVar(
    "audit_context", default=None
)


def set_audit_context(
    tenant_id: UUID | None = None,
    user_id: UUID | None = None,
    request_id: str | None = None,
    ip_address: str | None = None,
    user_agent: str | None = None,
) -> None:
    """Set the audit context for the current request.

    This should be called by middleware to provide context
    for automatic audit logging. Creates a new dict to ensure
    isolation between concurrent requests.

    Args:
        tenant_id: Current tenant ID
        user_id: Current user ID
        request_id: Request correlation ID
        ip_address: Client IP address
        user_agent: Client user agent
    """
    _audit_context.set(
        {
            "tenant_id": tenant_id,
            "user_id": user_id,
            "request_id": request_id,
            "ip_address": ip_address,
            "user_agent": user_agent,
        }
    )


def clear_audit_context() -> None:
    """Clear the audit context after request completes."""
    _audit_context.set(None)


def get_audit_context() -> dict[str, Any]:
    """Get the current audit context.

    Returns:
        Shallow copy of current audit context dict, or empty dict if not set
    """
    ctx = _audit_context.get()
    if ctx is None:
        return {}
    return ctx.copy()


def _serialize_value(value: Any) -> Any:
    """Serialize a value to JSON-compatible primitives.

    Recursively converts non-JSON-serializable types to their
    string or primitive representations.

    Args:
        value: Any value to serialize

    Returns:
        JSON-serializable representation of the value
    """
    # Pass through JSON primitives
    if value is None or isinstance(value, str | int | float | bool):
        return value

    # Handle specific types that need conversion
    result: Any
    if isinstance(value, UUID):
        result = str(value)
    elif isinstance(value, datetime | date):
        result = value.isoformat()
    elif isinstance(value, Decimal):
        result = str(value)
    elif isinstance(value, Enum):
        result = value.value
    elif isinstance(value, dict):
        result = {k: _serialize_value(v) for k, v in value.items()}
    elif isinstance(value, list | tuple | set | frozenset):
        result = [_serialize_value(item) for item in value]
    else:
        # Fallback: convert to string
        result = str(value)

    return result


def _get_changes(obj: Any) -> dict[str, dict[str, Any]]:
    """Extract changes from a modified object.

    Args:
        obj: SQLAlchemy model instance

    Returns:
        Dictionary of changes {field: {old: x, new: y}}
    """
    changes = {}
    mapper = inspect(obj.__class__)

    for attr in mapper.attrs:
        if attr.key.startswith("_"):
            continue

        history = inspect(obj).attrs[attr.key].history
        if history.has_changes():
            old_value = history.deleted[0] if history.deleted else None
            new_value = history.added[0] if history.added else None

            changes[attr.key] = {
                "old": _serialize_value(old_value),
                "new": _serialize_value(new_value),
            }

    return changes


def _should_audit(obj: Any) -> bool:
    """Check if an object should be audited.

    Args:
        obj: SQLAlchemy model instance

    Returns:
        True if the object has __audit__ = True
    """
    return getattr(obj, "__audit__", False)


def _create_audit_entry(
    session: Session,
    action: str,
    obj: Any,
    changes: dict[str, Any] | None = None,
) -> None:
    """Create an audit log entry for a model change.

    Args:
        session: SQLAlchemy session
        action: Action type (create, update, delete)
        obj: The affected model instance
        changes: Dictionary of field changes
    """
    context = get_audit_context()

    # Skip if no tenant context (shouldn't happen in normal operation)
    tenant_id = context.get("tenant_id")
    if not tenant_id:
        # Try to get tenant_id from the object itself
        tenant_id = getattr(obj, "tenant_id", None)
        if not tenant_id:
            log.warning(
                "audit_skipped_no_tenant",
                resource_type=obj.__tablename__,
                action=action,
            )
            return

    # Get resource ID
    resource_id = None
    if hasattr(obj, "id"):
        resource_id = str(obj.id)

    # Create audit entry
    entry = AuditLog(
        tenant_id=tenant_id,
        user_id=context.get("user_id"),
        action=action,
        resource_type=obj.__tablename__,
        resource_id=resource_id,
        request_id=context.get("request_id"),
        ip_address=context.get("ip_address"),
        user_agent=context.get("user_agent"),
        changes=changes,
    )

    session.add(entry)


def setup_audit_listeners() -> None:
    """Set up SQLAlchemy event listeners for automatic auditing.

    Call this during application startup to enable automatic
    audit logging for models with __audit__ = True.
    """

    @event.listens_for(Session, "before_flush")
    def before_flush(
        session: Session,
        _flush_context: Any,
        _instances: Any,
    ) -> None:
        """Capture changes before they're flushed to the database."""
        # Track new objects
        for obj in session.new:
            if _should_audit(obj):
                _create_audit_entry(session, "create", obj)

        # Track modified objects
        for obj in session.dirty:
            if _should_audit(obj) and session.is_modified(obj):
                changes = _get_changes(obj)
                if changes:  # Only audit if there are actual changes
                    _create_audit_entry(session, "update", obj, changes)

        # Track deleted objects
        for obj in session.deleted:
            if _should_audit(obj):
                _create_audit_entry(session, "delete", obj)
