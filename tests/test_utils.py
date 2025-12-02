"""Tests for arvo.utils module."""

import os
import shutil
import tempfile
from pathlib import Path

from arvo.utils import (
    generate_secret_key,
    get_cartridges_path,
    get_template_path,
    is_arvo_project,
    load_project_config,
    save_project_config,
)


class TestGetTemplatePath:
    """Tests for get_template_path function."""

    def test_returns_path(self, templates_path: Path) -> None:
        """Verify get_template_path returns a valid path."""
        result = get_template_path()
        assert isinstance(result, Path)
        assert result.exists()

    def test_path_contains_starter_template(self) -> None:
        """Verify the path points to starter template."""
        result = get_template_path()
        assert (result / "copier.yaml").exists() or (result / "copier.yml").exists()


class TestGetCartridgesPath:
    """Tests for get_cartridges_path function."""

    def test_returns_path(self, cartridges_path: Path) -> None:
        """Verify get_cartridges_path returns a valid path."""
        result = get_cartridges_path()
        assert isinstance(result, Path)
        assert result.exists()

    def test_path_contains_cartridges(self) -> None:
        """Verify the path contains cartridge directories."""
        result = get_cartridges_path()
        # Should have at least the billing cartridge
        assert (result / "billing").exists()


class TestGenerateSecretKey:
    """Tests for generate_secret_key function."""

    def test_generates_string(self) -> None:
        """Verify generate_secret_key returns a string."""
        result = generate_secret_key()
        assert isinstance(result, str)

    def test_default_length(self) -> None:
        """Verify default key length is reasonable."""
        result = generate_secret_key()
        # URL-safe base64 encoding: 32 bytes -> ~43 chars
        assert len(result) >= 40

    def test_custom_length(self) -> None:
        """Verify custom length is respected."""
        result = generate_secret_key(length=16)
        # 16 bytes -> ~22 chars in base64
        assert len(result) >= 20

    def test_generates_unique_keys(self) -> None:
        """Verify each call generates a unique key."""
        keys = {generate_secret_key() for _ in range(100)}
        assert len(keys) == 100


class TestIsArvoProject:
    """Tests for is_arvo_project function."""

    def test_returns_true_when_arvo_yaml_exists(self, temp_project: Path) -> None:
        """Verify returns True when .arvo.yaml exists."""
        assert is_arvo_project() is True

    def test_returns_false_when_not_arvo_project(self) -> None:
        """Verify returns False when .arvo.yaml doesn't exist."""
        temp_path = Path(tempfile.mkdtemp())
        original_dir = Path.cwd()
        try:
            os.chdir(temp_path)
            assert is_arvo_project() is False
        finally:
            os.chdir(original_dir)
            shutil.rmtree(temp_path, ignore_errors=True)


class TestProjectConfig:
    """Tests for load_project_config and save_project_config functions."""

    def test_load_returns_empty_dict_when_no_config(self) -> None:
        """Verify load_project_config returns empty dict when no config."""
        temp_path = Path(tempfile.mkdtemp())
        original_dir = Path.cwd()
        try:
            os.chdir(temp_path)
            result = load_project_config()
            assert result == {}
        finally:
            os.chdir(original_dir)
            shutil.rmtree(temp_path, ignore_errors=True)

    def test_load_returns_config_contents(self, temp_project: Path) -> None:
        """Verify load_project_config returns config contents."""
        result = load_project_config()
        assert "cartridges" in result

    def test_save_creates_config_file(self) -> None:
        """Verify save_project_config creates config file."""
        temp_path = Path(tempfile.mkdtemp())
        original_dir = Path.cwd()
        try:
            os.chdir(temp_path)
            config = {"cartridges": ["billing@1.0.0"]}
            save_project_config(config)

            assert (temp_path / ".arvo.yaml").exists()
            loaded = load_project_config()
            assert loaded == config
        finally:
            os.chdir(original_dir)
            shutil.rmtree(temp_path, ignore_errors=True)

    def test_save_overwrites_existing_config(self, temp_project: Path) -> None:
        """Verify save_project_config overwrites existing config."""
        new_config = {"cartridges": ["storage@2.0.0"], "version": "1.0"}
        save_project_config(new_config)

        loaded = load_project_config()
        assert loaded == new_config
