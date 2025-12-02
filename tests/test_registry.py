"""Tests for arvo.registry module."""

from pathlib import Path

import pytest

from arvo.registry import CartridgeRegistry
from arvo.schemas import CartridgeSpec


class TestCartridgeRegistry:
    """Tests for CartridgeRegistry class."""

    def test_init_with_cartridges_dir(self, cartridges_path: Path) -> None:
        """Verify registry initializes with cartridges directory."""
        registry = CartridgeRegistry(cartridges_path)
        assert registry.cartridges_dir == cartridges_path

    def test_list_available_returns_cartridges(self, cartridges_path: Path) -> None:
        """Verify list_available returns available cartridges."""
        registry = CartridgeRegistry(cartridges_path)
        cartridges = registry.list_available()

        assert isinstance(cartridges, list)
        assert len(cartridges) > 0
        assert all(isinstance(c, CartridgeSpec) for c in cartridges)

    def test_list_available_empty_dir(self, temp_dir: Path) -> None:
        """Verify list_available returns empty list for empty directory."""
        registry = CartridgeRegistry(temp_dir)
        cartridges = registry.list_available()

        assert cartridges == []

    def test_list_available_nonexistent_dir(self, temp_dir: Path) -> None:
        """Verify list_available handles nonexistent directory."""
        nonexistent = temp_dir / "nonexistent"
        registry = CartridgeRegistry(nonexistent)
        cartridges = registry.list_available()

        assert cartridges == []

    def test_exists_returns_true_for_existing_cartridge(
        self, cartridges_path: Path
    ) -> None:
        """Verify exists returns True for existing cartridge."""
        registry = CartridgeRegistry(cartridges_path)
        assert registry.exists("billing") is True

    def test_exists_returns_false_for_nonexistent_cartridge(
        self, cartridges_path: Path
    ) -> None:
        """Verify exists returns False for nonexistent cartridge."""
        registry = CartridgeRegistry(cartridges_path)
        assert registry.exists("nonexistent") is False

    def test_get_returns_cartridge_spec(self, cartridges_path: Path) -> None:
        """Verify get returns CartridgeSpec for existing cartridge."""
        registry = CartridgeRegistry(cartridges_path)
        spec = registry.get("billing")

        assert isinstance(spec, CartridgeSpec)
        assert spec.name == "billing"

    def test_get_raises_for_nonexistent_cartridge(self, cartridges_path: Path) -> None:
        """Verify get raises FileNotFoundError for nonexistent cartridge."""
        registry = CartridgeRegistry(cartridges_path)

        with pytest.raises(FileNotFoundError, match="not found"):
            registry.get("nonexistent")

    def test_get_caches_result(self, cartridges_path: Path) -> None:
        """Verify get caches cartridge specs."""
        registry = CartridgeRegistry(cartridges_path)

        spec1 = registry.get("billing")
        spec2 = registry.get("billing")

        assert spec1 is spec2

    def test_get_path_returns_cartridge_directory(self, cartridges_path: Path) -> None:
        """Verify get_path returns path to cartridge directory."""
        registry = CartridgeRegistry(cartridges_path)
        path = registry.get_path("billing")

        assert path == cartridges_path / "billing"
