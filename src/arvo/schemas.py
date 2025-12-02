"""Pydantic schemas for Arvo CLI."""

from pydantic import BaseModel, Field


class ConfigVar(BaseModel):
    """Configuration variable required by a cartridge."""

    key: str = Field(..., description="Environment variable name")
    description: str = Field(..., description="Human-readable description")
    required: bool = Field(True, description="Whether this variable is required")
    default: str | None = Field(None, description="Default value if not required")


class CartridgeSpec(BaseModel):
    """Specification for a cartridge (plugin)."""

    name: str = Field(..., description="Cartridge name (e.g., 'billing')")
    version: str = Field(..., description="Semantic version (e.g., '1.0.0')")
    description: str = Field(..., description="Short description of the cartridge")
    author: str | None = Field(None, description="Author name or organization")

    # Compatibility
    requires: dict[str, str] = Field(
        default_factory=dict,
        description="Required dependencies (e.g., {'arvo': '>=0.1.0'})",
    )

    # Python dependencies
    dependencies: list[str] = Field(
        default_factory=list,
        description="Python packages to add (e.g., ['stripe>=10.0.0'])",
    )

    # Configuration variables
    config: list[ConfigVar] = Field(
        default_factory=list,
        description="Environment variables required by this cartridge",
    )

    # Route configuration
    routes: dict[str, str | list[str]] = Field(
        default_factory=dict,
        description="Route configuration (prefix, tags)",
    )

    # File mappings
    files: dict[str, str] = Field(
        default_factory=dict,
        description="File path mappings (modules, migrations)",
    )

    # Post-install instructions
    post_install: str | None = Field(
        None, description="Instructions to show after installation"
    )


class ProjectConfig(BaseModel):
    """Configuration for an Arvo project (.arvo.yaml)."""

    arvo_version: str = Field(..., description="Arvo version used to create project")
    created_at: str = Field(..., description="ISO timestamp of project creation")
    cartridges: list[str] = Field(
        default_factory=list,
        description="Installed cartridges (e.g., ['billing@1.0.0'])",
    )

