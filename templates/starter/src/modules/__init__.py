"""Feature modules with auto-discovery."""

import logging
from importlib import import_module
from pathlib import Path

from fastapi import APIRouter


logger = logging.getLogger(__name__)


def discover_modules() -> list[APIRouter]:
    """Auto-discover and return routers from all modules.

    This function scans the modules directory for subdirectories
    that contain a router attribute in their __init__.py.

    Returns:
        List of FastAPI routers from discovered modules.
    """
    modules_dir = Path(__file__).parent
    routers: list[APIRouter] = []

    for path in sorted(modules_dir.iterdir()):
        if path.is_dir() and not path.name.startswith("_"):
            try:
                module = import_module(f"app.modules.{path.name}")
                if hasattr(module, "router"):
                    routers.append(module.router)
                    logger.info(f"Loaded module: {path.name}")
            except ImportError as e:
                logger.warning(f"Failed to load module {path.name}: {e}")

    return routers
