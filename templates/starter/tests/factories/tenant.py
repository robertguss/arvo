"""Factory for Tenant model."""

from uuid import uuid4

from polyfactory.factories.sqlalchemy_factory import SQLAlchemyFactory

from app.modules.tenants.models import Tenant


class TenantFactory(SQLAlchemyFactory):
    """Factory for generating Tenant test data."""

    __model__ = Tenant

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
