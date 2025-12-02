"""Tests for arvo.schemas module."""

import pytest
from pydantic import ValidationError

from arvo.schemas import CartridgeSpec, ConfigVar


class TestConfigVar:
    """Tests for ConfigVar schema."""

    def test_required_fields(self) -> None:
        """Verify required fields are enforced."""
        config_var = ConfigVar(
            key="STRIPE_SECRET_KEY",
            description="Stripe API secret key",
        )
        assert config_var.key == "STRIPE_SECRET_KEY"
        assert config_var.description == "Stripe API secret key"
        assert config_var.required is True  # default
        assert config_var.default is None

    def test_optional_fields(self) -> None:
        """Verify optional fields work correctly."""
        config_var = ConfigVar(
            key="LOG_LEVEL",
            description="Logging level",
            required=False,
            default="INFO",
        )
        assert config_var.required is False
        assert config_var.default == "INFO"


class TestCartridgeSpec:
    """Tests for CartridgeSpec schema."""

    def test_minimal_spec(self) -> None:
        """Verify minimal spec with only required fields."""
        spec = CartridgeSpec(
            name="test",
            version="1.0.0",
            description="Test cartridge",
        )
        assert spec.name == "test"
        assert spec.version == "1.0.0"
        assert spec.description == "Test cartridge"
        assert spec.dependencies == []
        assert spec.config == []
        assert spec.files == {}

    def test_full_spec(self) -> None:
        """Verify full spec with all fields."""
        spec = CartridgeSpec(
            name="billing",
            version="1.0.0",
            description="Stripe billing integration",
            dependencies=["stripe>=10.0.0"],
            config=[
                ConfigVar(
                    key="STRIPE_SECRET_KEY",
                    description="Stripe API key",
                    required=True,
                )
            ],
            files={"modules": "modules/billing", "migrations": "migrations"},
            docs="README.md",
            post_install="Run just migrate to apply migrations",
        )
        assert spec.name == "billing"
        assert len(spec.dependencies) == 1
        assert len(spec.config) == 1
        assert spec.files["modules"] == "modules/billing"
        assert spec.docs == "README.md"
        assert spec.post_install is not None

    def test_missing_required_fields(self) -> None:
        """Verify validation fails for missing required fields."""
        with pytest.raises(ValidationError):
            CartridgeSpec(name="test")  # type: ignore[call-arg]

    def test_config_from_dict(self) -> None:
        """Verify config can be initialized from dict."""
        spec = CartridgeSpec(
            name="test",
            version="1.0.0",
            description="Test",
            config=[
                {"key": "API_KEY", "description": "API key", "required": True},
            ],
        )
        assert len(spec.config) == 1
        assert spec.config[0].key == "API_KEY"
