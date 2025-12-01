#!/usr/bin/env python
"""
Generate demo/seed data for development.
"""

import argparse
import asyncio
import sys
from uuid import uuid4

from sqlalchemy import select


# Add src to path for imports
sys.path.insert(0, "src")

from app.core.database import async_session_factory
from app.modules.tenants.models import Tenant


async def seed_default() -> None:
    """Create default seed data."""
    async with async_session_factory() as session:
        # Check if default tenant exists
        result = await session.execute(select(Tenant).where(Tenant.slug == "default"))
        existing = result.scalar_one_or_none()

        if existing:
            print(f"Default tenant already exists: {existing.name}")
            return

        # Create default tenant
        tenant = Tenant(
            id=uuid4(),
            name="Default Organization",
            slug="default",
            is_active=True,
        )
        session.add(tenant)
        await session.commit()
        print(f"Created default tenant: {tenant.name} ({tenant.id})")


async def seed_demo() -> None:
    """Create demo data with multiple tenants."""
    async with async_session_factory() as session:
        tenants_data = [
            {"name": "Acme Corporation", "slug": "acme"},
            {"name": "Globex Industries", "slug": "globex"},
            {"name": "Initech", "slug": "initech"},
        ]

        for data in tenants_data:
            # Check if tenant exists
            result = await session.execute(
                select(Tenant).where(Tenant.slug == data["slug"])
            )
            existing = result.scalar_one_or_none()

            if existing:
                print(f"Tenant already exists: {existing.name}")
                continue

            tenant = Tenant(
                id=uuid4(),
                name=data["name"],
                slug=data["slug"],
                is_active=True,
            )
            session.add(tenant)
            print(f"Created tenant: {tenant.name}")

        await session.commit()


async def main(scenario: str) -> None:
    """Run the seeding based on scenario."""
    if scenario == "default":
        await seed_default()
    elif scenario == "demo":
        await seed_demo()
    else:
        print(f"Unknown scenario: {scenario}")
        print("Available scenarios: default, demo")
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed database with demo data")
    parser.add_argument(
        "--scenario",
        "-s",
        default="default",
        help="Seed scenario to run (default, demo)",
    )
    args = parser.parse_args()

    asyncio.run(main(args.scenario))
