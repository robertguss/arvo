"""Command: arvo list - List available cartridges."""

import typer
from rich.console import Console
from rich.table import Table


console = Console()


def list_cartridges(
    installed: bool = typer.Option(
        False, "--installed", "-i", help="Show only installed cartridges"
    ),
) -> None:
    """List available cartridges.

    Shows all cartridges that can be installed with 'arvo add'.
    """
    from arvo.registry import CartridgeRegistry
    from arvo.utils import get_cartridges_path, is_arvo_project, load_project_config

    registry = CartridgeRegistry(get_cartridges_path())
    cartridges = registry.list_available()

    if not cartridges:
        console.print("[yellow]No cartridges available.[/yellow]")
        return

    # Get installed cartridges if we're in a project
    installed_names: set[str] = set()
    if is_arvo_project():
        project_config = load_project_config()
        installed_names = {
            c.split("@")[0] for c in project_config.get("cartridges", [])
        }

    # Filter if --installed flag
    if installed:
        if not is_arvo_project():
            console.print(
                "[yellow]Warning:[/yellow] Not in an Arvo project. "
                "Showing all available cartridges."
            )
        else:
            cartridges = [c for c in cartridges if c.name in installed_names]
            if not cartridges:
                console.print("[yellow]No cartridges installed.[/yellow]")
                return

    # Build table
    table = Table(title="Available Cartridges", show_header=True)
    table.add_column("Name", style="cyan", no_wrap=True)
    table.add_column("Description")
    table.add_column("Version", style="green", no_wrap=True)
    if is_arvo_project():
        table.add_column("Status", no_wrap=True)

    for c in cartridges:
        row = [c.name, c.description, c.version]
        if is_arvo_project():
            if c.name in installed_names:
                row.append("[green]installed[/green]")
            else:
                row.append("")
        table.add_row(*row)

    console.print()
    console.print(table)
    console.print()
