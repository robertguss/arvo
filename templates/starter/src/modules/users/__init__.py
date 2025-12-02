"""Users module for user management and authentication."""

from fastapi import APIRouter


router = APIRouter(prefix="/users", tags=["users"])

# Import routes to register them (must be after router is defined)
from app.modules.users import routes  # noqa: F401, E402


# Module metadata
__module__ = {
    "name": "users",
    "version": "1.0.0",
    "description": "User management and authentication",
    "dependencies": ["tenants"],
}
