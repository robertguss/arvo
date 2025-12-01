"""Root API router with health endpoints and module mounting."""

from typing import Any

from fastapi import APIRouter, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy import text

from app.api.dependencies import DBSession
from app.config import settings
from app.modules import discover_modules


class HealthResponse(BaseModel):
    """Health check response schema."""

    status: str


class ReadinessResponse(BaseModel):
    """Readiness check response schema."""

    status: str
    checks: dict[str, str]


# Create root API router
api_router = APIRouter()

# Health check endpoints (no /api/v1 prefix)
health_router = APIRouter(tags=["health"])


@health_router.get(
    "/health/live",
    response_model=HealthResponse,
    summary="Liveness probe",
    description="Kubernetes liveness probe. Returns 200 if the process is running.",
)
async def liveness() -> HealthResponse:
    """Liveness probe endpoint."""
    return HealthResponse(status="alive")


@health_router.get(
    "/health/ready",
    response_model=ReadinessResponse,
    summary="Readiness probe",
    description="Kubernetes readiness probe. Checks database and cache connectivity.",
)
async def readiness(db: DBSession) -> JSONResponse:
    """Readiness probe endpoint."""
    checks: dict[str, str] = {}

    # Database check
    try:
        await db.execute(text("SELECT 1"))
        checks["database"] = "ok"
    except Exception as e:
        checks["database"] = str(e)

    # Note: Redis check will be added in Phase 2 with cache layer

    all_ok = all(v == "ok" for v in checks.values())

    return JSONResponse(
        status_code=status.HTTP_200_OK
        if all_ok
        else status.HTTP_503_SERVICE_UNAVAILABLE,
        content={
            "status": "ready" if all_ok else "degraded",
            "checks": checks,
        },
    )


@health_router.get(
    "/info",
    summary="Application info",
    description="Returns application metadata.",
)
async def info() -> dict[str, Any]:
    """Application info endpoint."""
    return {
        "app": settings.app_name,
        "environment": settings.environment,
        "debug": settings.debug,
    }


# Create versioned API router
v1_router = APIRouter(prefix="/api/v1")

# Mount discovered module routers
for module_router in discover_modules():
    v1_router.include_router(module_router)

# Include routers in main api_router
api_router.include_router(health_router)
api_router.include_router(v1_router)
