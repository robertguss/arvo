"""Command: arvo new - Create a new Arvo project."""

from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.panel import Panel


console = Console()


def new(
    project_name: str = typer.Argument(..., help="Name of the project to create"),
    output_dir: Annotated[
        Path | None,
        typer.Option("--output", "-o", help="Directory to create project in"),
    ] = None,
    no_git: bool = typer.Option(False, "--no-git", help="Skip git initialization"),
    # no_install reserved for future use
    no_install: bool = typer.Option(  # noqa: ARG001
        False, "--no-install", help="Skip dependency installation"
    ),
) -> None:
    """Create a new Arvo project.

    This scaffolds a complete FastAPI application with multi-tenancy,
    authentication, and all the production-ready features.
    """
    from copier import run_copy

    from arvo.utils import generate_secret_key, get_template_path, init_git

    base_dir = output_dir if output_dir is not None else Path()
    target = base_dir / project_name

    if target.exists():
        console.print(f"[red]Error:[/red] Directory '{target}' already exists")
        raise typer.Exit(1)

    console.print(
        f"\n[bold cyan]Creating new Arvo project:[/bold cyan] {project_name}\n"
    )

    # Generate data for template
    data = {
        "project_name": project_name,
        "project_slug": project_name.lower().replace(" ", "_").replace("-", "_"),
        "secret_key": generate_secret_key(),
    }

    try:
        with console.status("[bold green]Scaffolding project..."):
            run_copy(
                src_path=str(get_template_path()),
                dst_path=str(target),
                data=data,
                unsafe=True,
                quiet=True,
                defaults=True,  # Skip prompts, use defaults
            )
        console.print("[green]✓[/green] Created project structure")

        console.print("[green]✓[/green] Generated secret key")

        if not no_git:
            with console.status("[bold green]Initializing git..."):
                init_git(target)
            console.print("[green]✓[/green] Initialized git repository")

    except Exception as e:
        console.print(f"[red]Error:[/red] {e}")
        raise typer.Exit(1) from None

    # Display next steps
    console.print("\n")
    console.print(
        Panel(
            f"""[bold]Next steps:[/bold]

  [cyan]cd {project_name}[/cyan]
  [cyan]uv sync[/cyan]
  [cyan]just services[/cyan]
  [cyan]just migrate[/cyan]
  [cyan]just dev[/cyan]

Your API will be available at [link=http://localhost:8000]http://localhost:8000[/link]""",
            title="[bold green]Project created successfully![/bold green]",
            border_style="green",
        )
    )
