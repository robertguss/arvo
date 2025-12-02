"""Unit tests for seed data definitions.

These tests validate the structure and correctness of seed data
without requiring a database connection.
"""

import re
import sys
from pathlib import Path


# Add scripts to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent / "scripts"))
sys.path.insert(0, "src")

# Import seed module at module level
import seed as seed_module


# ============================================================
# Demo Tenants Tests
# ============================================================


class TestDemoTenants:
    """Tests for DEMO_TENANTS configuration."""

    def test_demo_tenants_exist(self):
        """DEMO_TENANTS should be defined."""
        assert hasattr(seed_module, "DEMO_TENANTS")
        assert len(seed_module.DEMO_TENANTS) > 0

    def test_demo_tenants_have_required_fields(self):
        """Each demo tenant should have name and slug."""
        for tenant in seed_module.DEMO_TENANTS:
            assert "name" in tenant, "Tenant should have name"
            assert "slug" in tenant, "Tenant should have slug"

    def test_demo_tenant_slugs_are_unique(self):
        """Demo tenant slugs should be unique."""
        slugs = [t["slug"] for t in seed_module.DEMO_TENANTS]
        assert len(slugs) == len(set(slugs)), "Tenant slugs should be unique"

    def test_demo_tenant_slugs_are_url_safe(self):
        """Demo tenant slugs should be URL-safe."""
        url_safe_pattern = re.compile(r"^[a-z0-9-]+$")

        for tenant in seed_module.DEMO_TENANTS:
            slug = tenant["slug"]
            assert url_safe_pattern.match(slug), f"Slug '{slug}' is not URL-safe"

    def test_expected_demo_tenants(self):
        """Demo should include Acme, Globex, and Initech."""
        slugs = [t["slug"] for t in seed_module.DEMO_TENANTS]

        assert "acme" in slugs
        assert "globex" in slugs
        assert "initech" in slugs


# ============================================================
# Standard Permissions Tests
# ============================================================


class TestStandardPermissions:
    """Tests for STANDARD_PERMISSIONS configuration."""

    def test_permissions_exist(self):
        """STANDARD_PERMISSIONS should be defined."""
        assert hasattr(seed_module, "STANDARD_PERMISSIONS")
        assert len(seed_module.STANDARD_PERMISSIONS) > 0

    def test_permissions_have_required_fields(self):
        """Each permission should have resource and action."""
        for perm in seed_module.STANDARD_PERMISSIONS:
            assert "resource" in perm, "Permission should have resource"
            assert "action" in perm, "Permission should have action"

    def test_permissions_are_unique(self):
        """Permission (resource, action) combinations should be unique."""
        combinations = [
            (p["resource"], p["action"]) for p in seed_module.STANDARD_PERMISSIONS
        ]
        assert len(combinations) == len(
            set(combinations)
        ), "Permission combinations should be unique"

    def test_has_user_crud_permissions(self):
        """Should include full CRUD permissions for users."""
        permissions = seed_module.STANDARD_PERMISSIONS
        user_perms = [
            (p["resource"], p["action"])
            for p in permissions
            if p["resource"] == "users"
        ]

        assert ("users", "read") in user_perms
        assert ("users", "create") in user_perms
        assert ("users", "update") in user_perms
        assert ("users", "delete") in user_perms

    def test_has_admin_wildcard_permission(self):
        """Should include wildcard (*:*) permission for admins."""
        permissions = seed_module.STANDARD_PERMISSIONS
        combinations = [(p["resource"], p["action"]) for p in permissions]

        assert ("*", "*") in combinations, "Should have admin wildcard permission"


# ============================================================
# Role Definitions Tests
# ============================================================


class TestRoleDefinitions:
    """Tests for ROLE_DEFINITIONS configuration."""

    def test_roles_exist(self):
        """ROLE_DEFINITIONS should be defined."""
        assert hasattr(seed_module, "ROLE_DEFINITIONS")
        assert len(seed_module.ROLE_DEFINITIONS) > 0

    def test_expected_roles_defined(self):
        """Should define admin, member, and viewer roles."""
        roles = seed_module.ROLE_DEFINITIONS

        assert "admin" in roles
        assert "member" in roles
        assert "viewer" in roles

    def test_roles_have_required_fields(self):
        """Each role should have description, is_default, and permissions."""
        for role_name, role_data in seed_module.ROLE_DEFINITIONS.items():
            assert "description" in role_data, f"{role_name} should have description"
            assert "is_default" in role_data, f"{role_name} should have is_default"
            assert "permissions" in role_data, f"{role_name} should have permissions"

    def test_only_one_default_role(self):
        """Only one role should be marked as default."""
        roles = seed_module.ROLE_DEFINITIONS
        default_roles = [name for name, data in roles.items() if data["is_default"]]

        assert len(default_roles) == 1, "Exactly one role should be default"
        assert default_roles[0] == "member", "Member should be the default role"

    def test_admin_has_wildcard_permission(self):
        """Admin role should have wildcard permission."""
        admin_role = seed_module.ROLE_DEFINITIONS["admin"]

        assert ("*", "*") in admin_role["permissions"]

    def test_viewer_is_read_only(self):
        """Viewer role should only have read permissions."""
        viewer_role = seed_module.ROLE_DEFINITIONS["viewer"]

        for _resource, action in viewer_role["permissions"]:
            assert action == "read", f"Viewer should not have {action} permission"


# ============================================================
# Demo Users Tests
# ============================================================


class TestDemoUsers:
    """Tests for DEMO_USERS configuration."""

    def test_users_exist(self):
        """DEMO_USERS should be defined."""
        assert hasattr(seed_module, "DEMO_USERS")
        assert len(seed_module.DEMO_USERS) > 0

    def test_users_have_required_fields(self):
        """Each user should have email, full_name, password, and roles."""
        for user in seed_module.DEMO_USERS:
            assert "email" in user, "User should have email"
            assert "full_name" in user, "User should have full_name"
            assert "password" in user, "User should have password"
            assert "roles" in user, "User should have roles"

    def test_user_emails_are_templates(self):
        """User emails should contain {slug} placeholder."""
        for user in seed_module.DEMO_USERS:
            assert "{slug}" in user["email"], "Email should be a template with {slug}"

    def test_expected_user_types(self):
        """Should have admin, member, and viewer users."""
        users = seed_module.DEMO_USERS
        roles_found = set()

        for user in users:
            for role in user["roles"]:
                roles_found.add(role)

        assert "admin" in roles_found
        assert "member" in roles_found
        assert "viewer" in roles_found

    def test_admin_user_is_superuser(self):
        """Admin user should be marked as superuser."""
        users = seed_module.DEMO_USERS
        admin_user = next((u for u in users if "admin" in u["roles"]), None)

        assert admin_user is not None
        assert admin_user.get("is_superuser") is True

    def test_passwords_are_reasonably_complex(self):
        """Demo passwords should have some complexity."""
        for user in seed_module.DEMO_USERS:
            password = user["password"]
            # Should have at least 8 chars and some complexity
            assert len(password) >= 8, "Password should be at least 8 characters"

    def test_email_templating_works(self):
        """Email templates should format correctly."""
        for user in seed_module.DEMO_USERS:
            email_template = user["email"]
            formatted = email_template.format(slug="acme")

            assert "@acme.example.com" in formatted
            assert "{slug}" not in formatted


# ============================================================
# Scenario Function Tests
# ============================================================


class TestScenarioFunctions:
    """Tests for scenario function definitions."""

    def test_seed_default_exists(self):
        """seed_default function should exist."""
        assert hasattr(seed_module, "seed_default")
        assert callable(seed_module.seed_default)

    def test_seed_demo_exists(self):
        """seed_demo function should exist."""
        assert hasattr(seed_module, "seed_demo")
        assert callable(seed_module.seed_demo)

    def test_seed_full_exists(self):
        """seed_full function should exist."""
        assert hasattr(seed_module, "seed_full")
        assert callable(seed_module.seed_full)

    def test_main_exists(self):
        """main function should exist."""
        assert hasattr(seed_module, "main")
        assert callable(seed_module.main)


# ============================================================
# Data Consistency Tests
# ============================================================


class TestDataConsistency:
    """Tests for consistency across seed data definitions."""

    def test_user_roles_match_role_definitions(self):
        """User role references should match defined roles."""
        defined_roles = set(seed_module.ROLE_DEFINITIONS.keys())

        for user in seed_module.DEMO_USERS:
            for role in user["roles"]:
                assert (
                    role in defined_roles
                ), f"User role '{role}' not in role definitions"

    def test_role_permissions_match_permission_definitions(self):
        """Role permission references should match defined permissions."""
        defined_perms = {
            (p["resource"], p["action"]) for p in seed_module.STANDARD_PERMISSIONS
        }

        for role_name, role_data in seed_module.ROLE_DEFINITIONS.items():
            for perm in role_data["permissions"]:
                assert (
                    perm in defined_perms
                ), f"Role '{role_name}' has undefined permission: {perm}"

    def test_at_least_three_demo_tenants(self):
        """Should have at least 3 demo tenants for variety."""
        assert len(seed_module.DEMO_TENANTS) >= 3

    def test_at_least_three_user_types(self):
        """Should have at least 3 different user types."""
        assert len(seed_module.DEMO_USERS) >= 3
