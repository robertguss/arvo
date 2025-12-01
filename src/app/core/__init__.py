"""Core services and cross-cutting concerns."""

from app.core.database import Base, get_db


__all__ = ["Base", "get_db"]
