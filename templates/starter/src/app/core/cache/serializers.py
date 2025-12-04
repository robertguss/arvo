"""Serialization utilities for caching.

Provides JSON serialization for Pydantic models and other
complex types used in cache values.
"""

import json
from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel


class CacheEncoder(json.JSONEncoder):
    """Custom JSON encoder for cache values.

    Handles:
    - Pydantic models
    - UUIDs
    - Datetimes
    - Sets (converted to lists)
    """

    def default(self, o: Any) -> Any:
        """Encode special types to JSON-serializable format.

        Args:
            o: Object to encode

        Returns:
            JSON-serializable representation
        """
        if isinstance(o, BaseModel):
            return {
                "__pydantic__": True,
                "__class__": o.__class__.__name__,
                "data": o.model_dump(mode="json"),
            }
        if isinstance(o, UUID):
            return {"__uuid__": True, "value": str(o)}
        if isinstance(o, datetime):
            return {"__datetime__": True, "value": o.isoformat()}
        if isinstance(o, set):
            return {"__set__": True, "value": list(o)}
        return super().default(o)


def serialize(value: Any) -> str:
    """Serialize a value for caching.

    Args:
        value: Value to serialize

    Returns:
        JSON string representation
    """
    return json.dumps(value, cls=CacheEncoder)


def deserialize(data: str) -> Any:
    """Deserialize a cached value.

    Args:
        data: JSON string from cache

    Returns:
        Deserialized Python object

    Note:
        Pydantic models are returned as dicts. The caller
        should reconstruct the model if needed.
    """
    return json.loads(data, object_hook=_decode_hook)


def _decode_hook(obj: dict[str, Any]) -> Any:
    """JSON decode hook for special types.

    Args:
        obj: Decoded JSON dict

    Returns:
        Reconstructed Python object
    """
    if "__uuid__" in obj:
        return UUID(obj["value"])
    if "__datetime__" in obj:
        return datetime.fromisoformat(obj["value"])
    if "__set__" in obj:
        return set(obj["value"])
    if "__pydantic__" in obj:
        # Return the data dict - caller reconstructs the model
        return obj["data"]
    return obj
