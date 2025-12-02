"""Command: arvo update - Update cartridges in the current project."""

import typer
from rich.console import Console

console = Console()


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
    from arvo.utils import is_arvo_project, load_project_config
    from arvo.registry import CartridgeRegistry
    from arvo.utils import get_cartridges_path

    # Check we're in an arvo project
    if not is_arvo_project():
        console.print(
            "[red]Error:[/red] Not in an Arvo project directory.\n"
            "Run this command from the root of an Arvo project."
        )
        raise typer.Exit(1)

    # Load project config
    project_config = load_project_config()
    installed = project_config.get("cartridges", [])

    if not installed:
        console.print("[yellow]No cartridges installed.[/yellow]")
        raise typer.Exit(0)

    # Load registry
    registry = CartridgeRegistry(get_cartridges_path())

    # If specific cartridge specified, check it's installed
    if cartridge_name:
        installed_names = [c.split("@")[0] for c in installed]
        if cartridge_name not in installed_names:
            console.print(
                f"[red]Error:[/red] Cartridge '{cartridge_name}' is not installed."
            )
            raise typer.Exit(1)
        cartridges_to_check = [cartridge_name]
    else:
        cartridges_to_check = [c.split("@")[0] for c in installed]

    console.print("\n[bold cyan]Checking for updates...[/bold cyan]\n")

    updates_available = []
    for name in cartridges_to_check:
        # Find installed version
        installed_version = None
        for c in installed:
            if c.startswith(f"{name}@"):
                installed_version = c.split("@")[1]
                break

        # Get latest version from registry
        if registry.exists(name):
            latest = registry.get(name)
            if installed_version and installed_version != latest.version:
                updates_available.append((name, installed_version, latest.version))
                console.print(
                    f"  [cyan]{name}[/cyan]: {installed_version} → [green]{latest.version}[/green]"
                )
            else:
                console.print(f"  [cyan]{name}[/cyan]: [dim]up to date[/dim]")
        else:
            console.print(
                f"  [cyan]{name}[/cyan]: [yellow]not found in registry[/yellow]"
            )

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

