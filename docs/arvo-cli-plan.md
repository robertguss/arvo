# Arvo CLI - Migration and Implementation Plan

**Version:** 1.0.0  
**Status:** Planning  
**Last Updated:** December 2024

---

## Executive Summary

Transform the `agency_python_starter_kit` repository into **Arvo** - a CLI tool that scaffolds new projects and manages cartridges (plugins). The current starter kit becomes a template that `arvo new` generates from.

### Vision

```bash
# Scaffold a new project
arvo new my-saas-app

# Add plugins/cartridges
arvo add billing
arvo add storage
arvo add notifications

# Manage cartridges
arvo list              # Show available cartridges
arvo update billing    # Update a cartridge
arvo remove billing    # Remove a cartridge
```

---

## Final Repository Structure

```
arvo/
├── src/arvo/                      # CLI package (NEW)
│   ├── __init__.py
│   ├── cli.py                     # Main Typer CLI app
│   ├── commands/
│   │   ├── __init__.py
│   │   ├── new.py                 # arvo new <project>
│   │   ├── add.py                 # arvo add <cartridge>
│   │   ├── remove.py              # arvo remove <cartridge>
│   │   ├── list.py                # arvo list
│   │   └── update.py              # arvo update <cartridge>
│   ├── registry.py                # Cartridge registry/index
│   ├── cartridge.py               # Cartridge management logic
│   └── utils.py                   # Helpers
│
├── templates/starter/             # Starter kit template (MOVED from src/app)
│   ├── src/app/                   # Current app code
│   ├── alembic/
│   ├── tests/
│   ├── deploy/
│   ├── docs/
│   ├── scripts/
│   ├── pyproject.toml.jinja       # Templated project config
│   ├── README.md.jinja
│   ├── .env.example
│   └── copier.yaml                # Copier configuration
│
├── cartridges/                    # Bundled cartridges (NEW)
│   └── billing/                   # First cartridge
│       ├── cartridge.yaml         # Cartridge metadata
│       ├── modules/billing/       # Module code
│       │   ├── __init__.py
│       │   ├── models.py
│       │   ├── schemas.py
│       │   ├── repos.py
│       │   ├── services.py
│       │   ├── routes.py
│       │   └── stripe_client.py
│       ├── migrations/
│       └── tests/
│
├── pyproject.toml                 # Arvo CLI package config
├── README.md                      # Arvo CLI readme
└── docs/                          # Arvo documentation
```

---

## Dependencies

```toml
[project]
name = "arvo"
version = "0.1.0"
description = "CLI for scaffolding projects and managing cartridges"
requires-python = ">=3.12"

dependencies = [
    # CLI Framework
    "typer>=0.12.0",     # Modern CLI with type hints, built-in prompts
    "rich>=13.0",        # Beautiful terminal output, tables, progress
    
    # Templating & Scaffolding
    "copier>=9.0",       # Use as library for project scaffolding
    
    # Configuration & Validation
    "pyyaml>=6.0",       # Parse cartridge.yaml
    "pydantic>=2.0",     # Validate cartridge schemas
    
    # File Manipulation
    "tomlkit>=0.12",     # Edit pyproject.toml preserving formatting
    
    # Git Operations
    "gitpython>=3.1",    # Initialize repos, check status
]

[project.scripts]
arvo = "arvo.cli:main"
```

### Library Rationale

| Library | Purpose |
|---------|---------|
| **Typer** | CLI framework by FastAPI's author - type hints, less boilerplate, Rich integration |
| **Rich** | Beautiful tables, progress bars, syntax highlighting, spinners |
| **Copier** | Scaffolding engine (used as library) - handles templating, answers file, future updates |
| **tomlkit** | Edit pyproject.toml without destroying comments/formatting |
| **GitPython** | Initialize git repos, check if in repo |
| **Pydantic** | Validate cartridge.yaml schemas |

---

## Implementation Phases

### Phase 1: Restructure Repository

**Goal:** Transform the current repo structure to support the CLI + template architecture.

#### 1.1 Move Starter Kit to Template

```bash
# Create template directory
mkdir -p templates/starter

# Move current code to template
mv src/app templates/starter/src/
mv alembic templates/starter/
mv tests templates/starter/
mv deploy templates/starter/
mv scripts templates/starter/
mv docs templates/starter/docs-template  # Keep arvo docs separate
```

#### 1.2 Create Template Variables

Files that need templating (rename to `.jinja`):

| File | Template Variables |
|------|-------------------|
| `pyproject.toml` | `{{ project_name }}`, `{{ project_slug }}`, `{{ description }}` |
| `README.md` | `{{ project_name }}`, `{{ description }}` |
| `.env.example` | `{{ database_name }}` |
| `docker-compose.yml` | `{{ project_slug }}` |
| `config.py` | `{{ project_name }}` |

#### 1.3 Create Copier Configuration

```yaml
# templates/starter/copier.yaml
_min_copier_version: "9.0.0"

project_name:
  type: str
  help: What is your project name?
  
project_slug:
  type: str
  default: "{{ project_name | lower | replace(' ', '_') | replace('-', '_') }}"
  
description:
  type: str
  default: "A FastAPI application built with Arvo"
  
database_name:
  type: str
  default: "{{ project_slug }}"
  
include_examples:
  type: bool
  default: true
  help: Include example modules?
```

#### 1.4 Create CLI Package Structure

```bash
mkdir -p src/arvo/commands
touch src/arvo/__init__.py
touch src/arvo/cli.py
touch src/arvo/commands/__init__.py
touch src/arvo/commands/{new,add,remove,list,update}.py
touch src/arvo/{registry,cartridge,utils}.py
```

#### 1.5 Update Root pyproject.toml

Change from starter kit package to arvo CLI package.

---

### Phase 2: Implement `arvo new`

**Goal:** Create the scaffolding command that generates new projects.

#### 2.1 CLI Implementation

```python
# src/arvo/commands/new.py
import typer
from rich.console import Console
from copier import run_copy
from pathlib import Path

console = Console()

def new(
    project_name: str = typer.Argument(..., help="Name of the project to create"),
    output_dir: Path = typer.Option(
        Path("."), "--output", "-o", help="Directory to create project in"
    ),
    no_git: bool = typer.Option(False, "--no-git", help="Skip git initialization"),
):
    """Create a new Arvo project."""
    
    target = output_dir / project_name
    
    with console.status(f"Creating project: {project_name}"):
        # Use Copier to generate from template
        run_copy(
            src_path=get_template_path(),
            dst_path=target,
            data={"project_name": project_name},
            unsafe=True,
        )
    
    console.print(f"[green]✓[/green] Created project: {project_name}")
    
    if not no_git:
        init_git(target)
        console.print("[green]✓[/green] Initialized git repository")
    
    # Display next steps
    console.print("\n[bold]Next steps:[/bold]")
    console.print(f"  cd {project_name}")
    console.print("  uv sync")
    console.print("  just services")
    console.print("  just migrate")
    console.print("  just dev")
```

#### 2.2 Expected UX

```bash
$ arvo new my-saas
Creating new Arvo project: my-saas

✓ Created project structure
✓ Generated secret key
✓ Initialized git repository

Next steps:
  cd my-saas
  uv sync
  just services
  just migrate
  just dev
```

---

### Phase 3: Cartridge System Foundation

**Goal:** Define the cartridge specification and registry system.

#### 3.1 Cartridge YAML Specification

```yaml
# cartridges/billing/cartridge.yaml
name: billing
version: 1.0.0
description: Stripe billing with subscriptions, invoices, and metered usage
author: Arvo Team

# Compatibility
requires:
  arvo: ">=0.1.0"

# Python dependencies to add
dependencies:
  - stripe>=10.0.0

# Environment variables needed
config:
  - key: STRIPE_SECRET_KEY
    description: Your Stripe secret key
    required: true
  - key: STRIPE_PUBLISHABLE_KEY
    description: Your Stripe publishable key
    required: true
  - key: STRIPE_WEBHOOK_SECRET
    description: Stripe webhook signing secret
    required: true

# Route configuration
routes:
  prefix: /billing
  tags: [billing]

# Files to copy
files:
  modules: modules/billing
  migrations: migrations/
  
# Post-install instructions
post_install: |
  1. Set the required config values in .env
  2. Run: just migrate
  3. Configure Stripe webhook to POST to /api/v1/billing/webhooks
```

#### 3.2 Pydantic Schema for Validation

```python
# src/arvo/schemas.py
from pydantic import BaseModel

class ConfigVar(BaseModel):
    key: str
    description: str
    required: bool = True
    default: str | None = None

class CartridgeSpec(BaseModel):
    name: str
    version: str
    description: str
    author: str | None = None
    requires: dict[str, str] = {}
    dependencies: list[str] = []
    config: list[ConfigVar] = []
    routes: dict[str, str] = {}
    files: dict[str, str] = {}
    post_install: str | None = None
```

#### 3.3 Registry System

```python
# src/arvo/registry.py
from pathlib import Path
import yaml
from .schemas import CartridgeSpec

class CartridgeRegistry:
    def __init__(self, cartridges_dir: Path):
        self.cartridges_dir = cartridges_dir
        self._cache: dict[str, CartridgeSpec] = {}
    
    def list_available(self) -> list[CartridgeSpec]:
        """List all available cartridges."""
        cartridges = []
        for path in self.cartridges_dir.iterdir():
            if path.is_dir() and (path / "cartridge.yaml").exists():
                cartridges.append(self.get(path.name))
        return cartridges
    
    def get(self, name: str) -> CartridgeSpec:
        """Get a cartridge by name."""
        if name not in self._cache:
            spec_path = self.cartridges_dir / name / "cartridge.yaml"
            with open(spec_path) as f:
                data = yaml.safe_load(f)
            self._cache[name] = CartridgeSpec(**data)
        return self._cache[name]
```

#### 3.4 `arvo list` Command

```python
# src/arvo/commands/list.py
import typer
from rich.console import Console
from rich.table import Table

console = Console()

def list_cartridges():
    """List available cartridges."""
    registry = get_registry()
    cartridges = registry.list_available()
    
    table = Table(title="Available Cartridges")
    table.add_column("Name", style="cyan")
    table.add_column("Description")
    table.add_column("Version", style="green")
    
    for c in cartridges:
        table.add_row(c.name, c.description, c.version)
    
    console.print(table)
```

**Expected Output:**

```bash
$ arvo list
                    Available Cartridges
┏━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━┓
┃ Name          ┃ Description                          ┃ Version ┃
┡━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━┩
│ billing       │ Stripe billing with subscriptions    │ 1.0.0   │
│ storage       │ S3/R2 file storage                   │ 1.0.0   │
│ email         │ Email templates with MJML            │ 0.1.0   │
└───────────────┴──────────────────────────────────────┴─────────┘
```

---

### Phase 4: Implement `arvo add`

**Goal:** Install cartridges into existing projects.

#### 4.1 Project Detection

Create a `.arvo.yaml` marker file in generated projects:

```yaml
# .arvo.yaml (in generated projects)
arvo_version: 0.1.0
created_at: 2024-12-02T10:30:00Z
cartridges: []
```

#### 4.2 `arvo add` Command

```python
# src/arvo/commands/add.py
import typer
from rich.console import Console
from pathlib import Path
import shutil
import tomlkit

console = Console()

def add(
    cartridge_name: str = typer.Argument(..., help="Name of the cartridge to install"),
    no_migrate: bool = typer.Option(False, "--no-migrate", help="Skip migration"),
):
    """Add a cartridge to the current project."""
    
    # Check we're in an arvo project
    if not Path(".arvo.yaml").exists():
        console.print("[red]Error:[/red] Not in an Arvo project directory")
        raise typer.Exit(1)
    
    registry = get_registry()
    cartridge = registry.get(cartridge_name)
    
    with console.status(f"Installing cartridge: {cartridge_name}"):
        # 1. Copy module files
        copy_module(cartridge)
        console.print(f"[green]✓[/green] Added {cartridge_name} module")
        
        # 2. Add dependencies to pyproject.toml
        add_dependencies(cartridge.dependencies)
        console.print("[green]✓[/green] Added dependencies")
        
        # 3. Copy migrations
        copy_migrations(cartridge)
        console.print("[green]✓[/green] Added migrations")
        
        # 4. Update .env.example
        add_config_vars(cartridge.config)
        console.print("[green]✓[/green] Updated .env.example")
        
        # 5. Update .arvo.yaml
        record_installation(cartridge)
    
    # Show required config
    if cartridge.config:
        console.print("\n[bold]Required configuration:[/bold]")
        for var in cartridge.config:
            if var.required:
                console.print(f"  {var.key}=  # {var.description}")
    
    # Post-install instructions
    if cartridge.post_install:
        console.print(f"\n[bold]Next steps:[/bold]")
        console.print(cartridge.post_install)
```

#### 4.3 Helper Functions

```python
def add_dependencies(deps: list[str]):
    """Add dependencies to pyproject.toml using tomlkit."""
    with open("pyproject.toml") as f:
        doc = tomlkit.load(f)
    
    project_deps = doc["project"]["dependencies"]
    for dep in deps:
        if dep not in project_deps:
            project_deps.append(dep)
    
    with open("pyproject.toml", "w") as f:
        tomlkit.dump(doc, f)
    
    # Run uv sync
    subprocess.run(["uv", "sync"], check=True)

def copy_module(cartridge: CartridgeSpec):
    """Copy module files to src/app/modules/"""
    src = get_cartridge_path(cartridge.name) / cartridge.files["modules"]
    dst = Path("src/app/modules") / cartridge.name
    shutil.copytree(src, dst)

def copy_migrations(cartridge: CartridgeSpec):
    """Copy migrations to alembic/versions/"""
    src = get_cartridge_path(cartridge.name) / cartridge.files["migrations"]
    dst = Path("alembic/versions")
    for migration in src.glob("*.py"):
        shutil.copy(migration, dst)
```

#### 4.4 Expected UX

```bash
$ arvo add billing
Installing cartridge: billing (1.0.0)

✓ Added billing module to src/app/modules/
✓ Added dependencies (stripe>=10.0.0)
✓ Added migration: 2024_01_15_add_billing_tables.py
✓ Updated .env.example

Required configuration:
  STRIPE_SECRET_KEY=     # Your Stripe secret key
  STRIPE_WEBHOOK_SECRET= # Webhook signing secret

Next steps:
  1. Set the config values in .env
  2. Run: just migrate
  3. Configure Stripe webhook endpoint
```

---

### Phase 5: Auto-Discovery for Routes

**Goal:** Avoid manually modifying `router.py` when cartridges are installed.

```python
# templates/starter/src/app/modules/__init__.py
"""Module auto-discovery for cartridge support."""
from importlib import import_module
from pathlib import Path
from fastapi import APIRouter

def discover_routers() -> list[APIRouter]:
    """
    Auto-discover routers from all modules.
    
    Each module should expose a `router` attribute in its __init__.py
    """
    routers = []
    modules_dir = Path(__file__).parent
    
    for module_path in modules_dir.iterdir():
        if module_path.is_dir() and not module_path.name.startswith("_"):
            try:
                module = import_module(f"app.modules.{module_path.name}")
                if hasattr(module, "router"):
                    routers.append(module.router)
            except ImportError:
                pass
    
    return routers


# Usage in router.py:
# from app.modules import discover_routers
# for router in discover_routers():
#     api_router.include_router(router, prefix="/api/v1")
```

---

### Phase 6: Build Billing Cartridge

**Goal:** Create the first real cartridge as a reference implementation.

#### 6.1 Structure

```
cartridges/billing/
├── cartridge.yaml
├── modules/
│   └── billing/
│       ├── __init__.py
│       ├── models.py          # StripeCustomer, Subscription, Invoice, etc.
│       ├── schemas.py         # Request/response schemas
│       ├── repos.py           # Data access
│       ├── services.py        # Billing business logic
│       ├── routes.py          # API endpoints
│       ├── webhooks.py        # Stripe webhook handlers
│       └── stripe_client.py   # Stripe SDK wrapper
├── migrations/
│   └── 001_add_billing_tables.py
└── tests/
    ├── test_services.py
    └── test_webhooks.py
```

#### 6.2 Key Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/billing/checkout` | POST | Create Stripe Checkout Session |
| `/billing/portal` | GET | Get Customer Portal URL |
| `/billing/subscription` | GET | Get current subscription |
| `/billing/subscription/cancel` | POST | Cancel subscription |
| `/billing/usage` | POST | Report metered usage |
| `/billing/invoices` | GET | List invoices |
| `/billing/webhooks` | POST | Stripe webhook endpoint |

---

## Key Files to Create

### CLI Core

| File | Purpose |
|------|---------|
| `src/arvo/__init__.py` | Package init with version |
| `src/arvo/cli.py` | Main Typer app with command groups |
| `src/arvo/commands/new.py` | Project scaffolding |
| `src/arvo/commands/add.py` | Cartridge installation |
| `src/arvo/commands/remove.py` | Cartridge removal |
| `src/arvo/commands/list.py` | List available cartridges |
| `src/arvo/commands/update.py` | Update installed cartridges |
| `src/arvo/registry.py` | Cartridge discovery and metadata |
| `src/arvo/cartridge.py` | Cartridge installation logic |
| `src/arvo/schemas.py` | Pydantic models for cartridge spec |
| `src/arvo/utils.py` | Helper functions |

### Templates

| File | Purpose |
|------|---------|
| `templates/starter/copier.yaml` | Copier configuration |
| `templates/starter/pyproject.toml.jinja` | Templated project config |
| `templates/starter/README.md.jinja` | Templated readme |
| `templates/starter/.arvo.yaml.jinja` | Project marker file |

---

## Estimated Effort

| Phase | Description | Effort |
|-------|-------------|--------|
| Phase 1 | Restructure repository | 3-4 hours |
| Phase 2 | Implement `arvo new` | 4-5 hours |
| Phase 3 | Cartridge system foundation | 3-4 hours |
| Phase 4 | Implement `arvo add` | 4-5 hours |
| Phase 5 | Auto-discovery for routes | 1-2 hours |
| Phase 6 | Build billing cartridge | 8-10 hours |

**Total: ~24-30 hours**

---

## Success Criteria

1. **`arvo new my-app`** creates a fully working project
2. **`arvo list`** shows available cartridges with rich formatting
3. **`arvo add billing`** installs billing module successfully
4. Generated project passes all tests
5. Clean, delightful CLI experience with Typer + Rich output
6. Copier-based templating enables future `arvo update` support
7. Cartridges are fully isolated and don't require manual route registration

---

## Future Enhancements

### Remote Cartridges
```bash
arvo add github:myorg/my-cartridge
arvo add https://example.com/cartridge.tar.gz
```

### Cartridge Updates
```bash
arvo update billing          # Update specific cartridge
arvo update --all            # Update all cartridges
```

### Project Updates
```bash
arvo upgrade                 # Update project to latest arvo template
```

### Cartridge Development
```bash
arvo cartridge new my-cartridge   # Scaffold new cartridge
arvo cartridge publish            # Publish to registry
```

---

## References

- [Typer Documentation](https://typer.tiangolo.com/)
- [Copier Documentation](https://copier.readthedocs.io/)
- [Rich Documentation](https://rich.readthedocs.io/)
- [FastAPI Project Structure](https://fastapi.tiangolo.com/tutorial/bigger-applications/)

