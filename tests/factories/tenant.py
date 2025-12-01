"""Factory for Tenant model."""

from uuid import uuid4

from polyfactory.factories.pydantic_factory import ModelFactory
from pydantic import BaseModel


class TenantCreate(BaseModel):
    """Schema for creating a tenant (for factory use)."""

    name: str
    slug: str
    is_active: bool = True


class TenantFactory(ModelFactory[TenantCreate]):
    """Factory for generating Tenant test data."""

    __model__ = TenantCreate

    @classmethod
    def name(cls) -> str:
        """Generate a company name."""
        return f"{cls.__faker__.company()} {cls.__faker__.company_suffix()}"

    @classmethod
    def slug(cls) -> str:
        """Generate a URL-safe slug."""
        return f"{cls.__faker__.slug()}-{uuid4().hex[:6]}"

    @classmethod
    def is_active(cls) -> bool:
        """Generate active status (default True)."""
        return True
