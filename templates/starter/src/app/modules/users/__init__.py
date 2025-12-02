"""Users module for user management and authentication."""

from fastapi import APIRouter


router = APIRouter(prefix="/users", tags=["users"])


# Module metadata
__module__ = {
    "name": "users",
    "version": "1.0.0",
    "description": "User management and authentication",
    "dependencies": ["tenants"],
}


def register_routes() -> None:
    """Register routes - called after all imports are complete."""
    from app.modules.users import routes  # noqa: F401
