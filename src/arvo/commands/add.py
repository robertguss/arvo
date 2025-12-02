"""Command: arvo add - Add a cartridge to the current project."""

import subprocess

import typer
from rich.console import Console


console = Console()


def add(
    cartridge_name: str = typer.Argument(..., help="Name of the cartridge to install"),
    no_sync: bool = typer.Option(
        False, "--no-sync", help="Skip running 'uv sync' after install"
    ),
    no_migrate: bool = typer.Option(
        False, "--no-migrate", help="Skip migration instructions"
    ),
) -> None:
    """Add a cartridge (plugin) to the current project.

    This installs the cartridge's module, dependencies, and migrations.
    """
    from arvo.cartridge import install_cartridge
    from arvo.registry import CartridgeRegistry
    from arvo.utils import get_cartridges_path, is_arvo_project, load_project_config

    # Check we're in an arvo project
    if not is_arvo_project():
        console.print(
            "[red]Error:[/red] Not in an Arvo project directory.\n"
            "Run this command from the root of an Arvo project (where .arvo.yaml exists)."
        )
        raise typer.Exit(1)

    # Load registry
    registry = CartridgeRegistry(get_cartridges_path())

    # Check cartridge exists
    if not registry.exists(cartridge_name):
        console.print(f"[red]Error:[/red] Cartridge '{cartridge_name}' not found.")
        console.print("\nAvailable cartridges:")
        for c in registry.list_available():
            console.print(f"  - {c.name}")
        raise typer.Exit(1)

    # Load cartridge spec
    cartridge = registry.get(cartridge_name)

    # Check if already installed
    project_config = load_project_config()
    installed = [c.split("@")[0] for c in project_config.get("cartridges", [])]
    if cartridge_name in installed:
        console.print(
            f"[yellow]Warning:[/yellow] Cartridge '{cartridge_name}' is already installed."
        )
        raise typer.Exit(0)

    console.print(
        f"\n[bold cyan]Installing cartridge:[/bold cyan] {cartridge.name} ({cartridge.version})\n"
    )

    try:
        # Install the cartridge
        install_cartridge(cartridge, console)

        # Run uv sync if not skipped
        if not no_sync:
            with console.status("[bold green]Running uv sync..."):
                subprocess.run(["uv", "sync"], check=True, capture_output=True)
            console.print("[green]✓[/green] Dependencies installed")

    except Exception as e:
        console.print(f"[red]Error:[/red] {e}")
        raise typer.Exit(1) from None

    # Show required config
    if cartridge.config:
        console.print("\n[bold]Required configuration:[/bold]")
        for var in cartridge.config:
            if var.required:
                console.print(f"  [cyan]{var.key}=[/cyan]  # {var.description}")

    # Show post-install instructions
    if cartridge.post_install:
        console.print("\n[bold]Next steps:[/bold]")
        console.print(cartridge.post_install)
    elif not no_migrate:
        console.print("\n[bold]Next steps:[/bold]")
        console.print("  1. Set the required config values in .env")
        console.print("  2. Run: [cyan]just migrate[/cyan]")
