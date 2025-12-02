"""Main Arvo CLI application."""

import typer
from rich.console import Console

from arvo import __version__
from arvo.commands import add, list_cmd, new, remove, update


console = Console()

app = typer.Typer(
    name="arvo",
    help="Scaffold projects and manage cartridges.",
    no_args_is_help=True,
    rich_markup_mode="rich",
)

# Register commands
app.command(name="new")(new.new)
app.command(name="add")(add.add)
app.command(name="list")(list_cmd.list_cartridges)
app.command(name="remove")(remove.remove)
app.command(name="update")(update.update)


@app.callback(invoke_without_command=True)
def version_callback(
    version: bool = typer.Option(
        False, "--version", "-v", help="Show version and exit."
    ),
) -> None:
    """Arvo CLI - Scaffold projects and manage cartridges."""
    if version:
        console.print(f"[bold cyan]arvo[/bold cyan] version {__version__}")
        raise typer.Exit()


def main() -> None:
    """Entry point for the CLI."""
    app()


if __name__ == "__main__":
    main()
