"""Cartridge registry for discovering and managing cartridges."""

import contextlib
from pathlib import Path

import yaml

from arvo.schemas import CartridgeSpec


class CartridgeRegistry:
    """Registry for discovering and loading cartridge specifications."""

    def __init__(self, cartridges_dir: Path):
        """Initialize the registry with a cartridges directory.

        Args:
            cartridges_dir: Path to the directory containing cartridges.
        """
        self.cartridges_dir = cartridges_dir
        self._cache: dict[str, CartridgeSpec] = {}

    def list_available(self) -> list[CartridgeSpec]:
        """List all available cartridges.

        Returns:
            List of CartridgeSpec objects for all available cartridges.
        """
        cartridges: list[CartridgeSpec] = []

        if not self.cartridges_dir.exists():
            return cartridges

        for path in sorted(self.cartridges_dir.iterdir()):
            if path.is_dir() and (path / "cartridge.yaml").exists():
                with contextlib.suppress(Exception):
                    cartridges.append(self.get(path.name))

        return cartridges

    def exists(self, name: str) -> bool:
        """Check if a cartridge exists.

        Args:
            name: Name of the cartridge.

        Returns:
            True if the cartridge exists, False otherwise.
        """
        spec_path = self.cartridges_dir / name / "cartridge.yaml"
        return spec_path.exists()

    def get(self, name: str) -> CartridgeSpec:
        """Get a cartridge specification by name.

        Args:
            name: Name of the cartridge.

        Returns:
            CartridgeSpec for the requested cartridge.

        Raises:
            FileNotFoundError: If the cartridge doesn't exist.
            ValueError: If the cartridge specification is invalid.
        """
        if name in self._cache:
            return self._cache[name]

        spec_path = self.cartridges_dir / name / "cartridge.yaml"

        if not spec_path.exists():
            raise FileNotFoundError(f"Cartridge '{name}' not found")

        with spec_path.open() as f:
            data = yaml.safe_load(f)

        try:
            spec = CartridgeSpec(**data)
        except Exception as e:
            raise ValueError(f"Invalid cartridge specification: {e}") from e

        self._cache[name] = spec
        return spec

    def get_path(self, name: str) -> Path:
        """Get the path to a cartridge directory.

        Args:
            name: Name of the cartridge.

        Returns:
            Path to the cartridge directory.
        """
        return self.cartridges_dir / name
