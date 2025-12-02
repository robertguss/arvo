"""Cartridge installation and management."""

import shutil
from pathlib import Path
from typing import Any, cast

import tomlkit
from rich.console import Console

from arvo.schemas import CartridgeSpec
from arvo.utils import get_cartridges_path, load_project_config, save_project_config


def install_cartridge(cartridge: CartridgeSpec, console: Console) -> None:
    """Install a cartridge into the current project.

    Args:
        cartridge: The cartridge specification to install.
        console: Rich console for output.
    """
    cartridge_path = get_cartridges_path() / cartridge.name

    # 1. Copy module files
    if "modules" in cartridge.files:
        src_modules = cartridge_path / cartridge.files["modules"]
        dst_modules = Path("src/app/modules") / cartridge.name

        if dst_modules.exists():
            console.print(
                f"[yellow]Warning:[/yellow] Module directory already exists: {dst_modules}"
            )
        else:
            shutil.copytree(src_modules, dst_modules)
            console.print(f"[green]✓[/green] Added {cartridge.name} module")

    # 1b. Copy documentation if present
    if cartridge.docs:
        src_docs = cartridge_path / cartridge.docs
        dst_docs = Path("src/app/modules") / cartridge.name / "README.md"

        if src_docs.exists() and dst_docs.parent.exists():
            shutil.copy(src_docs, dst_docs)
            console.print(f"[green]✓[/green] Added documentation: {dst_docs}")

    # 2. Add dependencies to pyproject.toml
    if cartridge.dependencies:
        add_dependencies(cartridge.dependencies)
        deps_str = ", ".join(cartridge.dependencies)
        console.print(f"[green]✓[/green] Added dependencies: {deps_str}")

    # 3. Copy migrations
    if "migrations" in cartridge.files:
        src_migrations = cartridge_path / cartridge.files["migrations"]
        dst_migrations = Path("alembic/versions")

        if src_migrations.exists() and dst_migrations.exists():
            for migration in src_migrations.glob("*.py"):
                dst_file = dst_migrations / migration.name
                if not dst_file.exists():
                    shutil.copy(migration, dst_file)
            console.print("[green]✓[/green] Added migrations")

    # 4. Update .env.example with config vars
    if cartridge.config:
        update_env_example(cartridge)
        console.print("[green]✓[/green] Updated .env.example")

    # 5. Record installation in .arvo.yaml
    record_installation(cartridge)
    console.print("[green]✓[/green] Updated project configuration")


def add_dependencies(deps: list[str]) -> None:
    """Add dependencies to pyproject.toml.

    Args:
        deps: List of dependency strings (e.g., ['stripe>=10.0.0']).
    """
    pyproject_path = Path("pyproject.toml")

    with pyproject_path.open() as f:
        doc = tomlkit.load(f)

    # Get or create dependencies list
    if "project" not in doc:
        doc["project"] = {}
    project = cast(dict[str, Any], doc["project"])
    if "dependencies" not in project:
        project["dependencies"] = []

    project_deps = cast(list[str], project["dependencies"])

    # Add each dependency if not already present
    for dep in deps:
        # Extract package name (before any version specifier)
        pkg_name = dep.split(">=")[0].split("==")[0].split("<")[0].split(">")[0]

        # Check if already in dependencies
        already_present = any(
            d.split(">=")[0].split("==")[0].split("<")[0].split(">")[0] == pkg_name
            for d in project_deps
        )

        if not already_present:
            project_deps.append(dep)

    with pyproject_path.open("w") as f:
        tomlkit.dump(doc, f)


def update_env_example(cartridge: CartridgeSpec) -> None:
    """Update .env.example with cartridge config variables.

    Args:
        cartridge: The cartridge specification.
    """
    env_path = Path(".env.example")
    content = "" if not env_path.exists() else env_path.read_text()

    # Add section header
    section = f"\n# {cartridge.name.title()} Cartridge\n"
    if section not in content:
        content += section

    # Add each config var
    for var in cartridge.config:
        line = f"{var.key}="
        if line not in content:
            if var.default:
                content += f"{var.key}={var.default}  # {var.description}\n"
            else:
                content += f"{var.key}=  # {var.description}\n"

    env_path.write_text(content)


def record_installation(cartridge: CartridgeSpec) -> None:
    """Record cartridge installation in .arvo.yaml.

    Args:
        cartridge: The installed cartridge specification.
    """
    config = load_project_config()

    if "cartridges" not in config:
        config["cartridges"] = []

    cartridge_entry = f"{cartridge.name}@{cartridge.version}"

    # Remove old version if present
    config["cartridges"] = [
        c for c in config["cartridges"] if not c.startswith(f"{cartridge.name}@")
    ]

    config["cartridges"].append(cartridge_entry)
    save_project_config(config)


def remove_cartridge(name: str, console: Console) -> None:
    """Remove a cartridge from the current project.

    Args:
        name: Name of the cartridge to remove.
        console: Rich console for output.
    """
    # 1. Remove module directory
    module_path = Path("src/app/modules") / name
    if module_path.exists():
        shutil.rmtree(module_path)
        console.print(f"[green]✓[/green] Removed module: {module_path}")

    # 2. Update .arvo.yaml
    config = load_project_config()
    config["cartridges"] = [
        c for c in config.get("cartridges", []) if not c.startswith(f"{name}@")
    ]
    save_project_config(config)
    console.print("[green]✓[/green] Updated project configuration")

    # Note: We don't remove dependencies or migrations for safety
    console.print("[dim]Note: Dependencies and migrations preserved for safety.[/dim]")
