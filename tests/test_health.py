"""Tests for health check endpoints."""

import pytest
from httpx import AsyncClient


@pytest.mark.asyncio
async def test_liveness_endpoint(client: AsyncClient):
    """Test that liveness endpoint returns 200."""
    response = await client.get("/health/live")

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "alive"


@pytest.mark.asyncio
async def test_readiness_endpoint(client: AsyncClient):
    """Test that readiness endpoint returns 200 with healthy checks."""
    response = await client.get("/health/ready")

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ready"
    assert "checks" in data
    assert data["checks"]["database"] == "ok"


@pytest.mark.asyncio
async def test_info_endpoint(client: AsyncClient):
    """Test that info endpoint returns application metadata."""
    response = await client.get("/info")

    assert response.status_code == 200
    data = response.json()
    assert "app" in data
    assert "environment" in data
