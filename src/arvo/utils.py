"""Utility functions for Arvo CLI."""

import importlib.resources
import secrets
from importlib.resources import as_file
from pathlib import Path
from typing import Any

import yaml


def get_template_path() -> Path:
    """Get the path to the starter template."""
    # First check if we're in a development environment (running from source)
    source_path = Path(__file__).parent.parent.parent / "templates" / "starter"
    if source_path.exists():
        return source_path

    # Otherwise, look for installed package location
    try:
        ref = importlib.resources.files("arvo").joinpath("templates/starter")
        with as_file(ref) as p:
            return Path(p)
    except (TypeError, FileNotFoundError):
        pass

    raise FileNotFoundError(
        "Could not find template directory. " "Make sure Arvo is installed correctly."
    )


def get_cartridges_path() -> Path:
    """Get the path to the cartridges directory."""
    # First check if we're in a development environment
    source_path = Path(__file__).parent.parent.parent / "cartridges"
    if source_path.exists():
        return source_path

    # Otherwise, look for installed package location
    try:
        ref = importlib.resources.files("arvo").joinpath("cartridges")
        with as_file(ref) as p:
            return Path(p)
    except (TypeError, FileNotFoundError):
        pass

    raise FileNotFoundError(
        "Could not find cartridges directory. " "Make sure Arvo is installed correctly."
    )


def generate_secret_key(length: int = 32) -> str:
    """Generate a secure secret key."""
    return secrets.token_urlsafe(length)


def init_git(path: Path) -> None:
    """Initialize a git repository at the given path."""
    from git import Repo

    repo = Repo.init(path)
    # Create initial .gitignore if it doesn't exist
    gitignore = path / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text(
            """# Python
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
build/
develop-eggs/
dist/
downloads/
eggs/
.eggs/
lib/
lib64/
parts/
sdist/
var/
wheels/
*.egg-info/
.installed.cfg
*.egg

# Virtual environments
.venv/
venv/
ENV/

# IDE
.idea/
.vscode/
*.swp
*.swo

# Environment
.env
.env.local
.env.*.local

# Testing
.pytest_cache/
.coverage
htmlcov/
.mypy_cache/
.ruff_cache/

# Project specific
*.db
*.sqlite3
"""
        )

    # Stage all files and create initial commit
    repo.index.add(["."])
    repo.index.commit("Initial commit from Arvo")


def is_arvo_project() -> bool:
    """Check if the current directory is an Arvo project."""
    return Path(".arvo.yaml").exists()


def load_project_config() -> dict[str, Any]:
    """Load the project's .arvo.yaml configuration."""
    config_path = Path(".arvo.yaml")
    if not config_path.exists():
        return {}

    with config_path.open() as f:
        return yaml.safe_load(f) or {}


def save_project_config(config: dict[str, Any]) -> None:
    """Save the project's .arvo.yaml configuration."""
    with Path(".arvo.yaml").open("w") as f:
        yaml.dump(config, f, default_flow_style=False)
