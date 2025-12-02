"""API layer - routing and dependencies."""


def get_api_router():
    """Import router lazily to avoid circular imports."""
    from app.api.router import api_router

    return api_router


__all__ = ["get_api_router"]
