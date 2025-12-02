"""Tenants module - Multi-tenancy support."""

from fastapi import APIRouter


router = APIRouter(prefix="/tenants", tags=["tenants"])

# Module metadata
__module_info__ = {
    "name": "tenants",
    "version": "1.0.0",
    "description": "Multi-tenancy support module",
    "dependencies": [],
}
