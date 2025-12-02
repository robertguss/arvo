"""Tests for arvo CLI commands."""

import os
import shutil
import tempfile
from pathlib import Path

from typer.testing import CliRunner

from arvo.cli import app


runner = CliRunner()


class TestListCommand:
    """Tests for arvo list command."""

    def test_list_shows_available_cartridges(self) -> None:
        """Verify list command shows available cartridges."""
        result = runner.invoke(app, ["list"])

        assert result.exit_code == 0
        assert "billing" in result.stdout.lower()

    def test_list_installed_in_non_project_dir(self) -> None:
        """Verify list --installed works outside project."""
        temp_path = Path(tempfile.mkdtemp())
        original_dir = Path.cwd()
        try:
            os.chdir(temp_path)
            result = runner.invoke(app, ["list", "--installed"])

            # Should still work, just show nothing installed
            assert result.exit_code == 0
        finally:
            os.chdir(original_dir)
            shutil.rmtree(temp_path, ignore_errors=True)


class TestNewCommand:
    """Tests for arvo new command."""

    def test_new_creates_project(self) -> None:
        """Verify new command creates a project."""
        temp_path = Path(tempfile.mkdtemp())
        try:
            result = runner.invoke(
                app, ["new", "test-project", "--output", str(temp_path), "--no-git"]
            )

            assert result.exit_code == 0, f"Command failed: {result.stdout}"
            project_dir = temp_path / "test-project"
            assert project_dir.exists()
            assert (project_dir / "pyproject.toml").exists()
        finally:
            shutil.rmtree(temp_path, ignore_errors=True)

    def test_new_fails_if_directory_exists(self) -> None:
        """Verify new command fails if directory exists."""
        temp_path = Path(tempfile.mkdtemp())
        try:
            # Create the directory first
            (temp_path / "existing-project").mkdir()

            result = runner.invoke(
                app, ["new", "existing-project", "--output", str(temp_path)]
            )

            assert result.exit_code == 1
            assert "already exists" in result.stdout.lower()
        finally:
            shutil.rmtree(temp_path, ignore_errors=True)


class TestAddCommand:
    """Tests for arvo add command."""

    def test_add_fails_outside_project(self) -> None:
        """Verify add command fails outside arvo project."""
        temp_path = Path(tempfile.mkdtemp())
        original_dir = Path.cwd()
        try:
            os.chdir(temp_path)
            result = runner.invoke(app, ["add", "billing"])

            assert result.exit_code == 1
            assert "not in an arvo project" in result.stdout.lower()
        finally:
            os.chdir(original_dir)
            shutil.rmtree(temp_path, ignore_errors=True)

    def test_add_fails_for_nonexistent_cartridge(self, temp_project: Path) -> None:
        """Verify add command fails for nonexistent cartridge."""
        result = runner.invoke(app, ["add", "nonexistent"])

        assert result.exit_code == 1
        assert "not found" in result.stdout.lower()


class TestRemoveCommand:
    """Tests for arvo remove command."""

    def test_remove_fails_outside_project(self) -> None:
        """Verify remove command fails outside arvo project."""
        temp_path = Path(tempfile.mkdtemp())
        original_dir = Path.cwd()
        try:
            os.chdir(temp_path)
            result = runner.invoke(app, ["remove", "billing"])

            assert result.exit_code == 1
            assert "not in an arvo project" in result.stdout.lower()
        finally:
            os.chdir(original_dir)
            shutil.rmtree(temp_path, ignore_errors=True)

    def test_remove_warns_for_not_installed(self, temp_project: Path) -> None:
        """Verify remove command warns if cartridge not installed."""
        result = runner.invoke(app, ["remove", "billing", "--force"])

        assert result.exit_code == 0
        assert "not installed" in result.stdout.lower()


class TestUpdateCommand:
    """Tests for arvo update command."""

    def test_update_fails_outside_project(self) -> None:
        """Verify update command fails outside arvo project."""
        temp_path = Path(tempfile.mkdtemp())
        original_dir = Path.cwd()
        try:
            os.chdir(temp_path)
            result = runner.invoke(app, ["update"])

            assert result.exit_code == 1
            assert "not in an arvo project" in result.stdout.lower()
        finally:
            os.chdir(original_dir)
            shutil.rmtree(temp_path, ignore_errors=True)

    def test_update_with_no_cartridges(self, temp_project: Path) -> None:
        """Verify update command handles no installed cartridges."""
        result = runner.invoke(app, ["update"])

        assert result.exit_code == 0
        assert "no cartridges" in result.stdout.lower()
