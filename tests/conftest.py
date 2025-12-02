"""Pytest configuration and shared fixtures for CLI tests."""

import os
import shutil
import tempfile
from collections.abc import Generator
from pathlib import Path

import pytest


@pytest.fixture
def temp_dir() -> Generator[Path, None, None]:
    """Create a temporary directory for test operations.

    Yields:
        Path to the temporary directory
    """
    temp_path = Path(tempfile.mkdtemp())
    yield temp_path
    shutil.rmtree(temp_path, ignore_errors=True)


@pytest.fixture
def temp_project() -> Generator[Path, None, None]:
    """Create a temporary project directory with .arvo.yaml.

    Yields:
        Path to the temporary project directory
    """
    # Save original directory FIRST before anything else
    original_dir = Path.cwd()

    # Create temp directory
    temp_path = Path(tempfile.mkdtemp())

    try:
        # Create minimal arvo project structure
        (temp_path / ".arvo.yaml").write_text("cartridges: []\n")
        (temp_path / "pyproject.toml").write_text(
            '[project]\nname = "test-project"\ndependencies = []\n'
        )
        (temp_path / "src" / "app" / "modules").mkdir(parents=True)

        os.chdir(temp_path)

        yield temp_path
    finally:
        os.chdir(original_dir)
        shutil.rmtree(temp_path, ignore_errors=True)


@pytest.fixture
def cartridges_path() -> Path:
    """Get the path to the cartridges directory."""
    return Path(__file__).parent.parent / "cartridges"


@pytest.fixture
def templates_path() -> Path:
    """Get the path to the templates directory."""
    return Path(__file__).parent.parent / "templates"
