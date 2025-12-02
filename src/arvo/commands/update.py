"""Command: arvo update - Update cartridges in the current project."""

from typing import TYPE_CHECKING

import typer
from rich.console import Console


if TYPE_CHECKING:
    from arvo.registry import CartridgeRegistry

console = Console()


def _get_installed_version(name: str, installed: list[str]) -> str | None:
    """Find installed version for a cartridge."""
    for c in installed:
        if c.startswith(f"{name}@"):
            return c.split("@")[1]
    return None


def _check_cartridge_update(
    name: str,
    installed: list[str],
    registry: "CartridgeRegistry",
) -> tuple[str, str, str] | None:
    """Check if a cartridge has an update available."""
    installed_version = _get_installed_version(name, installed)

    if not registry.exists(name):
        console.print(f"  [cyan]{name}[/cyan]: [yellow]not found in registry[/yellow]")
        return None

    latest = registry.get(name)
    if installed_version and installed_version != latest.version:
        console.print(
            f"  [cyan]{name}[/cyan]: {installed_version} → [green]{latest.version}[/green]"
        )
        return (name, installed_version, latest.version)

    console.print(f"  [cyan]{name}[/cyan]: [dim]up to date[/dim]")
    return None


def update(
    cartridge_name: str = typer.Argument(
        None, help="Name of the cartridge to update (updates all if not specified)"
    ),
    check: bool = typer.Option(
        False, "--check", "-c", help="Check for updates without installing"
    ),
) -> None:
    """Update installed cartridges to the latest version.

    If no cartridge name is provided, checks/updates all installed cartridges.
    """
    from arvo.registry import CartridgeRegistry
    from arvo.utils import get_cartridges_path, is_arvo_project, load_project_config

    # Check we're in an arvo project
    if not is_arvo_project():
        console.print(
            "[red]Error:[/red] Not in an Arvo project directory.\n"
            "Run this command from the root of an Arvo project."
        )
        raise typer.Exit(1)

    # Load project config
    project_config = load_project_config()
    installed: list[str] = project_config.get("cartridges", [])

    if not installed:
        console.print("[yellow]No cartridges installed.[/yellow]")
        raise typer.Exit(0)

    # Load registry
    registry = CartridgeRegistry(get_cartridges_path())

    # Determine which cartridges to check
    cartridges_to_check = _get_cartridges_to_check(cartridge_name, installed)
    if cartridges_to_check is None:
        raise typer.Exit(1)

    console.print("\n[bold cyan]Checking for updates...[/bold cyan]\n")

    # Check each cartridge for updates
    updates_available = [
        update_info
        for name in cartridges_to_check
        if (update_info := _check_cartridge_update(name, installed, registry))
    ]

    _display_update_results(updates_available, check)


def _get_cartridges_to_check(
    cartridge_name: str | None, installed: list[str]
) -> list[str] | None:
    """Get list of cartridges to check for updates."""
    installed_names = [c.split("@")[0] for c in installed]

    if cartridge_name:
        if cartridge_name not in installed_names:
            console.print(
                f"[red]Error:[/red] Cartridge '{cartridge_name}' is not installed."
            )
            return None
        return [cartridge_name]

    return installed_names


def _display_update_results(
    updates_available: list[tuple[str, str, str]], check: bool
) -> None:
    """Display update check results."""
    if not updates_available:
        console.print("\n[green]All cartridges are up to date.[/green]")
        return

    if check:
        console.print(
            f"\n[bold]{len(updates_available)} update(s) available.[/bold] "
            "Run without --check to install."
        )
        return

    # TODO: Implement actual update logic
    console.print(
        "\n[yellow]Update installation not yet implemented.[/yellow]\n"
        "For now, remove and re-add the cartridge:\n"
        f"  arvo remove {updates_available[0][0]}\n"
        f"  arvo add {updates_available[0][0]}"
    )
