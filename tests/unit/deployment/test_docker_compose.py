"""Unit tests for Docker Compose configuration files.

These tests validate the structure and content of docker-compose files
without requiring Docker to be installed.
"""

from pathlib import Path

import pytest
import yaml


# ============================================================
# Test Fixtures
# ============================================================

DEPLOY_DIR = Path(__file__).parent.parent.parent.parent / "deploy"


@pytest.fixture
def dev_compose() -> dict:
    """Load development docker-compose.yml."""
    compose_path = DEPLOY_DIR / "docker-compose.yml"
    with compose_path.open() as f:
        return yaml.safe_load(f)


@pytest.fixture
def prod_compose() -> dict:
    """Load production docker-compose.prod.yml."""
    compose_path = DEPLOY_DIR / "docker-compose.prod.yml"
    with compose_path.open() as f:
        return yaml.safe_load(f)


# ============================================================
# Development Docker Compose Tests
# ============================================================


class TestDevDockerCompose:
    """Tests for development docker-compose.yml."""

    def test_file_exists(self):
        """docker-compose.yml should exist in deploy directory."""
        compose_path = DEPLOY_DIR / "docker-compose.yml"
        assert compose_path.exists(), "docker-compose.yml not found"

    def test_has_postgres_service(self, dev_compose: dict):
        """Development compose should include PostgreSQL service."""
        assert "postgres" in dev_compose["services"]

        postgres = dev_compose["services"]["postgres"]
        assert "postgres:16" in postgres["image"]
        assert "5432:5432" in postgres["ports"]
        assert postgres.get("healthcheck") is not None

    def test_has_redis_service(self, dev_compose: dict):
        """Development compose should include Redis service."""
        assert "redis" in dev_compose["services"]

        redis = dev_compose["services"]["redis"]
        assert "redis:7" in redis["image"]
        assert "6379:6379" in redis["ports"]
        assert redis.get("healthcheck") is not None

    def test_has_volumes(self, dev_compose: dict):
        """Development compose should define persistent volumes."""
        assert "volumes" in dev_compose
        assert "postgres_data" in dev_compose["volumes"]
        assert "redis_data" in dev_compose["volumes"]


# ============================================================
# Production Docker Compose Tests
# ============================================================


class TestProdDockerCompose:
    """Tests for production docker-compose.prod.yml."""

    def test_file_exists(self):
        """docker-compose.prod.yml should exist in deploy directory."""
        compose_path = DEPLOY_DIR / "docker-compose.prod.yml"
        assert compose_path.exists(), "docker-compose.prod.yml not found"

    def test_has_app_service(self, prod_compose: dict):
        """Production compose should include app service."""
        assert "app" in prod_compose["services"]

        app = prod_compose["services"]["app"]
        assert app.get("build") is not None
        assert app.get("healthcheck") is not None
        assert app.get("depends_on") is not None
        assert "restart" in app

    def test_has_worker_service(self, prod_compose: dict):
        """Production compose should include ARQ worker service."""
        assert "worker" in prod_compose["services"]

        worker = prod_compose["services"]["worker"]
        assert "arq" in worker.get("command", "")
        assert worker.get("depends_on") is not None

    def test_has_postgres_service(self, prod_compose: dict):
        """Production compose should include PostgreSQL service."""
        assert "postgres" in prod_compose["services"]

        postgres = prod_compose["services"]["postgres"]
        assert "postgres:16" in postgres["image"]
        assert postgres.get("healthcheck") is not None
        # Should NOT expose ports in production
        assert "ports" not in postgres

    def test_has_redis_service(self, prod_compose: dict):
        """Production compose should include Redis service."""
        assert "redis" in prod_compose["services"]

        redis = prod_compose["services"]["redis"]
        assert "redis:7" in redis["image"]
        assert redis.get("healthcheck") is not None
        # Should NOT expose ports in production
        assert "ports" not in redis

    def test_has_caddy_service(self, prod_compose: dict):
        """Production compose should include Caddy reverse proxy."""
        assert "caddy" in prod_compose["services"]

        caddy = prod_compose["services"]["caddy"]
        assert "caddy:2" in caddy["image"]
        # Should expose HTTP and HTTPS ports
        assert "80:80" in caddy["ports"]
        assert "443:443" in caddy["ports"]

    def test_has_networks(self, prod_compose: dict):
        """Production compose should define internal and web networks."""
        assert "networks" in prod_compose
        assert "internal" in prod_compose["networks"]
        assert "web" in prod_compose["networks"]

    def test_has_volumes(self, prod_compose: dict):
        """Production compose should define all required volumes."""
        assert "volumes" in prod_compose
        volumes = prod_compose["volumes"]

        assert "postgres_data" in volumes
        assert "redis_data" in volumes
        assert "caddy_data" in volumes
        assert "caddy_config" in volumes

    def test_app_depends_on_postgres_and_redis(self, prod_compose: dict):
        """App service should depend on postgres and redis being healthy."""
        app = prod_compose["services"]["app"]
        depends_on = app.get("depends_on", {})

        assert "postgres" in depends_on
        assert "redis" in depends_on
        # Should use health check conditions
        assert depends_on["postgres"].get("condition") == "service_healthy"
        assert depends_on["redis"].get("condition") == "service_healthy"

    def test_app_uses_env_file(self, prod_compose: dict):
        """App service should load environment from .env.prod."""
        app = prod_compose["services"]["app"]
        assert ".env.prod" in app.get("env_file", "")

    def test_worker_uses_env_file(self, prod_compose: dict):
        """Worker service should load environment from .env.prod."""
        worker = prod_compose["services"]["worker"]
        assert ".env.prod" in worker.get("env_file", "")

    def test_services_have_resource_limits(self, prod_compose: dict):
        """Production services should have memory limits."""
        for service_name in ["app", "worker", "postgres", "redis", "caddy"]:
            service = prod_compose["services"][service_name]
            deploy = service.get("deploy", {})
            resources = deploy.get("resources", {})

            # Should have limits defined
            assert "limits" in resources, f"{service_name} should have resource limits"
            assert "memory" in resources["limits"]

    def test_caddy_mounts_caddyfile(self, prod_compose: dict):
        """Caddy service should mount Caddyfile configuration."""
        caddy = prod_compose["services"]["caddy"]
        volumes = caddy.get("volumes", [])

        caddyfile_mounted = any("Caddyfile" in v for v in volumes)
        assert caddyfile_mounted, "Caddy should mount Caddyfile"

    def test_internal_services_not_exposed(self, prod_compose: dict):
        """Internal services (postgres, redis, worker) should not expose ports."""
        internal_services = ["postgres", "redis", "worker"]

        for service_name in internal_services:
            service = prod_compose["services"][service_name]
            assert "ports" not in service, f"{service_name} should not expose ports"


# ============================================================
# Dockerfile Tests
# ============================================================


class TestDockerfile:
    """Tests for Dockerfile configuration."""

    def test_dockerfile_exists(self):
        """Production Dockerfile should exist."""
        dockerfile_path = DEPLOY_DIR / "Dockerfile"
        assert dockerfile_path.exists(), "Dockerfile not found"

    def test_dockerfile_dev_exists(self):
        """Development Dockerfile should exist."""
        dockerfile_path = DEPLOY_DIR / "Dockerfile.dev"
        assert dockerfile_path.exists(), "Dockerfile.dev not found"

    def test_dockerfile_uses_multistage_build(self):
        """Production Dockerfile should use multi-stage build."""
        dockerfile_path = DEPLOY_DIR / "Dockerfile"
        content = dockerfile_path.read_text()

        # Should have multiple FROM statements
        from_count = content.count("FROM ")
        assert from_count >= 2, "Dockerfile should use multi-stage build"

    def test_dockerfile_uses_nonroot_user(self):
        """Production Dockerfile should run as non-root user."""
        dockerfile_path = DEPLOY_DIR / "Dockerfile"
        content = dockerfile_path.read_text()

        assert "useradd" in content or "adduser" in content
        assert "USER " in content

    def test_dockerfile_has_healthcheck(self):
        """Production Dockerfile should define HEALTHCHECK."""
        dockerfile_path = DEPLOY_DIR / "Dockerfile"
        content = dockerfile_path.read_text()

        assert "HEALTHCHECK" in content

    def test_dockerfile_exposes_port_8000(self):
        """Production Dockerfile should expose port 8000."""
        dockerfile_path = DEPLOY_DIR / "Dockerfile"
        content = dockerfile_path.read_text()

        assert "EXPOSE 8000" in content


# ============================================================
# Caddyfile Tests
# ============================================================


class TestCaddyfile:
    """Tests for Caddyfile configuration."""

    def test_caddyfile_exists(self):
        """Caddyfile should exist in deploy directory."""
        caddyfile_path = DEPLOY_DIR / "Caddyfile"
        assert caddyfile_path.exists(), "Caddyfile not found"

    def test_caddyfile_has_reverse_proxy(self):
        """Caddyfile should configure reverse proxy to app."""
        caddyfile_path = DEPLOY_DIR / "Caddyfile"
        content = caddyfile_path.read_text()

        assert "reverse_proxy" in content
        assert "app:8000" in content

    def test_caddyfile_has_health_check(self):
        """Caddyfile should configure health checks."""
        caddyfile_path = DEPLOY_DIR / "Caddyfile"
        content = caddyfile_path.read_text()

        assert "health_uri" in content
        assert "/health/live" in content

    def test_caddyfile_has_security_headers(self):
        """Caddyfile should set security headers."""
        caddyfile_path = DEPLOY_DIR / "Caddyfile"
        content = caddyfile_path.read_text()

        security_headers = [
            "X-Content-Type-Options",
            "X-Frame-Options",
            "Referrer-Policy",
        ]

        for header in security_headers:
            assert header in content, f"Caddyfile should set {header} header"

    def test_caddyfile_enables_compression(self):
        """Caddyfile should enable gzip compression."""
        caddyfile_path = DEPLOY_DIR / "Caddyfile"
        content = caddyfile_path.read_text()

        assert "encode" in content
        assert "gzip" in content

    def test_caddyfile_configures_logging(self):
        """Caddyfile should configure JSON logging."""
        caddyfile_path = DEPLOY_DIR / "Caddyfile"
        content = caddyfile_path.read_text()

        assert "log" in content
        assert "json" in content


# ============================================================
# Environment Template Tests
# ============================================================


class TestEnvTemplate:
    """Tests for production environment template."""

    def test_env_template_exists(self):
        """env.prod.example should exist in deploy directory."""
        env_path = DEPLOY_DIR / "env.prod.example"
        assert env_path.exists(), "env.prod.example not found"

    def test_env_template_has_required_vars(self):
        """Environment template should include all required variables."""
        env_path = DEPLOY_DIR / "env.prod.example"
        content = env_path.read_text()

        required_vars = [
            "SECRET_KEY",
            "DB_USER",
            "DB_PASSWORD",
            "DB_NAME",
            "DOMAIN",
            "ACME_EMAIL",
        ]

        for var in required_vars:
            assert var in content, f"env.prod.example should include {var}"

    def test_env_template_has_oauth_vars(self):
        """Environment template should include OAuth configuration."""
        env_path = DEPLOY_DIR / "env.prod.example"
        content = env_path.read_text()

        oauth_vars = [
            "GOOGLE_CLIENT_ID",
            "GOOGLE_CLIENT_SECRET",
            "GITHUB_CLIENT_ID",
            "GITHUB_CLIENT_SECRET",
        ]

        for var in oauth_vars:
            assert var in content, f"env.prod.example should include {var}"

    def test_env_template_has_security_notes(self):
        """Environment template should include security documentation."""
        env_path = DEPLOY_DIR / "env.prod.example"
        content = env_path.read_text()

        # Should have security guidance
        assert "SECURITY" in content.upper() or "secret" in content.lower()
        assert "never" in content.lower() or "NEVER" in content
