#!/usr/bin/env python
"""
Generate demo/seed data for development and testing.

Scenarios:
- default: Create a single default tenant
- demo: Create multiple demo tenants
- full: Create comprehensive demo with tenants, users, roles, and permissions

Usage:
    python scripts/seed.py                    # Run default scenario
    python scripts/seed.py --scenario demo    # Run demo scenario
    python scripts/seed.py --scenario full    # Run full scenario with users/roles
"""

import argparse
import asyncio
import sys
from typing import TypedDict
from uuid import uuid4


# Add src to path for imports
sys.path.insert(0, "src")

from sqlalchemy import select

from app.core.auth.backend import hash_password
from app.core.database import async_session_factory
from app.core.permissions.models import Permission, Role, UserRole
from app.modules.tenants.models import Tenant
from app.modules.users.models import User


# ============================================================
# Type Definitions
# ============================================================


class PermissionData(TypedDict):
    resource: str
    action: str
    description: str


class RoleData(TypedDict):
    description: str
    is_default: bool
    permissions: list[tuple[str, str]]


class UserData(TypedDict):
    email: str
    full_name: str
    password: str
    is_superuser: bool
    roles: list[str]


class TenantData(TypedDict):
    name: str
    slug: str


# ============================================================
# Demo Data Definitions
# ============================================================

DEMO_TENANTS: list[TenantData] = [
    {"name": "Acme Corporation", "slug": "acme"},
    {"name": "Globex Industries", "slug": "globex"},
    {"name": "Initech", "slug": "initech"},
]

# Standard permissions for the platform
STANDARD_PERMISSIONS: list[PermissionData] = [
    # Users
    {"resource": "users", "action": "read", "description": "View users"},
    {"resource": "users", "action": "create", "description": "Create users"},
    {"resource": "users", "action": "update", "description": "Update users"},
    {"resource": "users", "action": "delete", "description": "Delete users"},
    # Projects (placeholder for future module)
    {"resource": "projects", "action": "read", "description": "View projects"},
    {"resource": "projects", "action": "create", "description": "Create projects"},
    {"resource": "projects", "action": "update", "description": "Update projects"},
    {"resource": "projects", "action": "delete", "description": "Delete projects"},
    # Settings
    {"resource": "settings", "action": "read", "description": "View settings"},
    {"resource": "settings", "action": "update", "description": "Update settings"},
    # Billing (placeholder for future cartridge)
    {"resource": "billing", "action": "read", "description": "View billing"},
    {"resource": "billing", "action": "manage", "description": "Manage billing"},
    # Admin
    {"resource": "*", "action": "*", "description": "Full administrative access"},
]

# Role definitions with their permissions
ROLE_DEFINITIONS: dict[str, RoleData] = {
    "admin": {
        "description": "Full access to all resources",
        "is_default": False,
        "permissions": [("*", "*")],  # Wildcard - all permissions
    },
    "member": {
        "description": "Standard team member access",
        "is_default": True,
        "permissions": [
            ("users", "read"),
            ("projects", "read"),
            ("projects", "create"),
            ("projects", "update"),
            ("settings", "read"),
        ],
    },
    "viewer": {
        "description": "Read-only access",
        "is_default": False,
        "permissions": [
            ("users", "read"),
            ("projects", "read"),
            ("settings", "read"),
        ],
    },
}

# Demo users per tenant
DEMO_USERS: list[UserData] = [
    {
        "email": "admin@{slug}.example.com",
        "full_name": "Admin User",
        "password": "admin123!@#",
        "is_superuser": True,
        "roles": ["admin"],
    },
    {
        "email": "member@{slug}.example.com",
        "full_name": "Team Member",
        "password": "member123!@#",
        "is_superuser": False,
        "roles": ["member"],
    },
    {
        "email": "viewer@{slug}.example.com",
        "full_name": "View Only User",
        "password": "viewer123!@#",
        "is_superuser": False,
        "roles": ["viewer"],
    },
]


# ============================================================
# Seed Functions
# ============================================================


async def seed_default() -> None:
    """Create default seed data with a single tenant."""
    async with async_session_factory() as session:
        # Check if default tenant exists
        result = await session.execute(select(Tenant).where(Tenant.slug == "default"))
        existing = result.scalar_one_or_none()

        if existing:
            print(f"✓ Default tenant already exists: {existing.name}")
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
        print(f"✓ Created default tenant: {tenant.name} ({tenant.id})")


async def seed_demo() -> None:
    """Create demo data with multiple tenants."""
    async with async_session_factory() as session:
        created_count = 0
        for data in DEMO_TENANTS:
            # Check if tenant exists
            result = await session.execute(
                select(Tenant).where(Tenant.slug == data["slug"])
            )
            existing = result.scalar_one_or_none()

            if existing:
                print(f"✓ Tenant already exists: {existing.name}")
                continue

            tenant = Tenant(
                id=uuid4(),
                name=data["name"],
                slug=data["slug"],
                is_active=True,
            )
            session.add(tenant)
            print(f"✓ Created tenant: {tenant.name}")
            created_count += 1

        await session.commit()
        print(f"\n📊 Created {created_count} new tenants")


async def seed_permissions(session) -> dict[tuple[str, str], Permission]:
    """Create standard permissions and return a lookup dict."""
    permissions_map: dict[tuple[str, str], Permission] = {}

    for perm_data in STANDARD_PERMISSIONS:
        key = (perm_data["resource"], perm_data["action"])

        # Check if permission exists
        result = await session.execute(
            select(Permission).where(
                Permission.resource == perm_data["resource"],
                Permission.action == perm_data["action"],
            )
        )
        existing = result.scalar_one_or_none()

        if existing:
            permissions_map[key] = existing
        else:
            permission = Permission(
                id=uuid4(),
                resource=perm_data["resource"],
                action=perm_data["action"],
                description=perm_data["description"],
            )
            session.add(permission)
            permissions_map[key] = permission
            print(
                f"  ✓ Created permission: {perm_data['resource']}:{perm_data['action']}"
            )

    await session.flush()
    return permissions_map


async def seed_roles_for_tenant(
    session,
    tenant: Tenant,
    permissions_map: dict[tuple[str, str], Permission],
) -> dict[str, Role]:
    """Create roles for a tenant and return a lookup dict."""
    roles_map: dict[str, Role] = {}

    for role_name, role_data in ROLE_DEFINITIONS.items():
        # Check if role exists for this tenant
        result = await session.execute(
            select(Role).where(
                Role.tenant_id == tenant.id,
                Role.name == role_name,
            )
        )
        existing = result.scalar_one_or_none()

        if existing:
            roles_map[role_name] = existing
        else:
            role = Role(
                id=uuid4(),
                tenant_id=tenant.id,
                name=role_name,
                description=role_data["description"],
                is_default=role_data["is_default"],
            )

            # Add permissions to role
            for resource, action in role_data["permissions"]:
                perm_key = (resource, action)
                if perm_key in permissions_map:
                    role.permissions.append(permissions_map[perm_key])

            session.add(role)
            roles_map[role_name] = role
            print(f"    ✓ Created role: {role_name}")

    await session.flush()
    return roles_map


async def seed_users_for_tenant(
    session,
    tenant: Tenant,
    roles_map: dict[str, Role],
) -> list[User]:
    """Create demo users for a tenant."""
    created_users: list[User] = []

    for user_data in DEMO_USERS:
        email = user_data["email"].format(slug=tenant.slug)

        # Check if user exists
        result = await session.execute(
            select(User).where(
                User.tenant_id == tenant.id,
                User.email == email,
            )
        )
        existing = result.scalar_one_or_none()

        if existing:
            print(f"    ✓ User already exists: {email}")
            continue

        user = User(
            id=uuid4(),
            tenant_id=tenant.id,
            email=email,
            full_name=user_data["full_name"],
            password_hash=hash_password(user_data["password"]),
            is_active=True,
            is_superuser=user_data["is_superuser"],
        )
        session.add(user)
        await session.flush()  # Get user.id

        # Assign roles
        for role_name in user_data["roles"]:
            if role_name in roles_map:
                user_role = UserRole(
                    user_id=user.id,
                    role_id=roles_map[role_name].id,
                )
                session.add(user_role)

        created_users.append(user)
        print(f"    ✓ Created user: {email} (roles: {', '.join(user_data['roles'])})")

    await session.flush()
    return created_users


async def seed_full() -> None:
    """Create comprehensive demo with tenants, users, roles, and permissions."""
    print("🚀 Starting full demo seeding...\n")

    async with async_session_factory() as session:
        # Step 1: Create permissions (global)
        print("📋 Creating permissions...")
        permissions_map = await seed_permissions(session)
        print(f"   Total permissions: {len(permissions_map)}\n")

        # Step 2: Create tenants with users and roles
        tenants_created = 0
        users_created = 0

        for tenant_data in DEMO_TENANTS:
            print(f"🏢 Processing tenant: {tenant_data['name']}")

            # Check/create tenant
            result = await session.execute(
                select(Tenant).where(Tenant.slug == tenant_data["slug"])
            )
            tenant = result.scalar_one_or_none()

            if not tenant:
                tenant = Tenant(
                    id=uuid4(),
                    name=tenant_data["name"],
                    slug=tenant_data["slug"],
                    is_active=True,
                )
                session.add(tenant)
                await session.flush()
                tenants_created += 1
                print(f"  ✓ Created tenant: {tenant.name}")
            else:
                print(f"  ✓ Tenant exists: {tenant.name}")

            # Create roles for tenant
            print("  📋 Creating roles...")
            roles_map = await seed_roles_for_tenant(session, tenant, permissions_map)

            # Create users for tenant
            print("  👥 Creating users...")
            users = await seed_users_for_tenant(session, tenant, roles_map)
            users_created += len(users)

            print()

        await session.commit()

        # Summary
        print("=" * 50)
        print("✅ Full demo seeding complete!")
        print(f"   Tenants created: {tenants_created}")
        print(f"   Users created: {users_created}")
        print(f"   Permissions: {len(permissions_map)}")
        print(f"   Roles per tenant: {len(ROLE_DEFINITIONS)}")
        print()
        print("📝 Demo credentials:")
        print("   Format: {role}@{tenant-slug}.example.com")
        print("   Passwords: admin123!@#, member123!@#, viewer123!@#")
        print()
        print("   Examples:")
        print("   - admin@acme.example.com / admin123!@#")
        print("   - member@globex.example.com / member123!@#")
        print("   - viewer@initech.example.com / viewer123!@#")


async def main(scenario: str) -> None:
    """Run the seeding based on scenario."""
    scenarios = {
        "default": seed_default,
        "demo": seed_demo,
        "full": seed_full,
    }

    if scenario not in scenarios:
        print(f"❌ Unknown scenario: {scenario}")
        print(f"Available scenarios: {', '.join(scenarios.keys())}")
        sys.exit(1)

    await scenarios[scenario]()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed database with demo data")
    parser.add_argument(
        "--scenario",
        "-s",
        default="default",
        choices=["default", "demo", "full"],
        help="Seed scenario to run (default, demo, full)",
    )
    args = parser.parse_args()

    asyncio.run(main(args.scenario))
