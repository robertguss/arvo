"""Command: arvo remove - Remove a cartridge from the current project."""

import typer
from rich.console import Console

console = Console()


def remove(
    cartridge_name: str = typer.Argument(..., help="Name of the cartridge to remove"),
    force: bool = typer.Option(
        False, "--force", "-f", help="Skip confirmation prompt"
    ),
) -> None:
    """Remove a cartridge from the current project.

    This removes the cartridge's module files but preserves migrations
    and database tables (for safety).
    """
    from arvo.utils import is_arvo_project, load_project_config

    # Check we're in an arvo project
    if not is_arvo_project():
        console.print(
            "[red]Error:[/red] Not in an Arvo project directory.\n"
            "Run this command from the root of an Arvo project."
        )
        raise typer.Exit(1)

    # Check if cartridge is installed
    project_config = load_project_config()
    installed = [c.split("@")[0] for c in project_config.get("cartridges", [])]

    if cartridge_name not in installed:
        console.print(
            f"[yellow]Warning:[/yellow] Cartridge '{cartridge_name}' is not installed."
        )
        raise typer.Exit(0)

    # Confirm removal
    if not force:
        confirm = typer.confirm(
            f"Are you sure you want to remove '{cartridge_name}'?\n"
            "This will delete the module files but preserve database tables."
        )
        if not confirm:
            console.print("[yellow]Cancelled.[/yellow]")
            raise typer.Exit(0)

    console.print(f"\n[bold cyan]Removing cartridge:[/bold cyan] {cartridge_name}\n")

    try:
        from arvo.cartridge import remove_cartridge

        remove_cartridge(cartridge_name, console)
        console.print(f"\n[green]✓[/green] Removed cartridge: {cartridge_name}")
        console.print(
            "\n[dim]Note: Database tables were preserved. "
            "Remove them manually if needed.[/dim]"
        )

    except Exception as e:
        console.print(f"[red]Error:[/red] {e}")
        raise typer.Exit(1)

