"""Application configuration using pydantic-settings."""

from functools import lru_cache

from pydantic import PostgresDsn, RedisDsn, computed_field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.core.constants import DEFAULT_INSECURE_SECRET, MIN_SECRET_KEY_LENGTH


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # Application
    app_name: str = "Agency Standard"
    debug: bool = False
    environment: str = "development"  # development, staging, production
    secret_key: str = DEFAULT_INSECURE_SECRET

    # Database
    database_url: PostgresDsn = PostgresDsn(
        "postgresql://postgres:postgres@localhost:5432/agency_standard"
    )
    database_pool_size: int = 25
    database_max_overflow: int = 50
    database_echo: bool = False

    # CORS
    cors_origins: list[str] = []

    # API Documentation
    api_docs_base_url: str = "https://api.example.com"

    @field_validator("secret_key")
    @classmethod
    def validate_secret_key(cls, v: str) -> str:
        """Validate that secret_key is secure in production.

        Args:
            v: The secret key value

        Returns:
            The validated secret key

        Raises:
            ValueError: If secret key is insecure in production
        """
        # Get environment from the data being validated
        # Note: In pydantic v2, we need to handle this differently
        # The validation happens before all fields are set
        # So we check the value itself rather than environment
        if v == DEFAULT_INSECURE_SECRET:
            # We'll do a runtime check in is_production instead
            # to allow development mode to use default
            pass
        elif len(v) < MIN_SECRET_KEY_LENGTH:
            raise ValueError(
                f"SECRET_KEY must be at least {MIN_SECRET_KEY_LENGTH} characters. "
                "Generate one with: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
            )
        return v

    # Redis
    redis_url: RedisDsn = RedisDsn("redis://localhost:6379")

    # Auth
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 7

    # OAuth (optional - for Phase 2)
    google_client_id: str | None = None
    google_client_secret: str | None = None
    microsoft_client_id: str | None = None
    microsoft_client_secret: str | None = None
    github_client_id: str | None = None
    github_client_secret: str | None = None

    # Rate Limiting
    rate_limit_requests: int = 100
    rate_limit_window: int = 60

    # Observability
    otlp_endpoint: str | None = None
    log_level: str = "INFO"

    @computed_field  # type: ignore[prop-decorator]
    @property
    def async_database_url(self) -> str:
        """Convert standard PostgreSQL URL to async version."""
        return str(self.database_url).replace("postgresql://", "postgresql+asyncpg://")

    @computed_field  # type: ignore[prop-decorator]
    @property
    def is_production(self) -> bool:
        """Check if running in production environment.

        Raises:
            ValueError: If using insecure secret key in production
        """
        is_prod = self.environment == "production"
        if is_prod and self.secret_key == DEFAULT_INSECURE_SECRET:
            raise ValueError(
                "SECRET_KEY must be set to a secure value in production. "
                "Generate one with: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
            )
        return is_prod

    @computed_field  # type: ignore[prop-decorator]
    @property
    def is_development(self) -> bool:
        """Check if running in development environment."""
        return self.environment == "development"


@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()


# Global settings instance
settings = get_settings()
