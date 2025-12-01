"""OAuth2 authentication with external providers.

This module provides OAuth2 integration for:
- Google (implemented)
- Microsoft (placeholder for future)
- GitHub (placeholder for future)

The flow:
1. Client redirects to /auth/oauth/{provider}/authorize
2. User authenticates with the provider
3. Provider redirects back to /auth/oauth/{provider}/callback
4. System creates/links user account and issues tokens
"""

import secrets
from typing import Any, ClassVar
from urllib.parse import urlencode

import httpx
import structlog
from pydantic import BaseModel

from app.config import settings


logger = structlog.get_logger()


class OAuthUserInfo(BaseModel):
    """User information from OAuth provider."""

    email: str
    name: str
    provider: str
    provider_id: str
    picture: str | None = None


class OAuthProvider:
    """Base class for OAuth providers."""

    name: str
    authorize_url: str
    token_url: str
    userinfo_url: str
    scopes: list[str]
    client_id: str | None
    client_secret: str | None

    def __init__(self) -> None:
        self.client_id = None
        self.client_secret = None

    @property
    def is_configured(self) -> bool:
        """Check if the provider is properly configured."""
        return bool(self.client_id and self.client_secret)

    def get_authorize_url(self, redirect_uri: str, state: str) -> str:
        """Generate the authorization URL.

        Args:
            redirect_uri: The callback URL after authorization
            state: CSRF protection state parameter

        Returns:
            The full authorization URL
        """
        params = {
            "client_id": self.client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": " ".join(self.scopes),
            "state": state,
        }
        return f"{self.authorize_url}?{urlencode(params)}"

    async def exchange_code(
        self,
        code: str,
        redirect_uri: str,
    ) -> dict[str, Any]:
        """Exchange authorization code for tokens.

        Args:
            code: The authorization code
            redirect_uri: The callback URL (must match authorize)

        Returns:
            Token response from the provider
        """
        async with httpx.AsyncClient() as client:
            response = await client.post(
                self.token_url,
                data={
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "code": code,
                    "redirect_uri": redirect_uri,
                    "grant_type": "authorization_code",
                },
                headers={"Accept": "application/json"},
            )
            response.raise_for_status()
            return response.json()

    async def get_user_info(self, access_token: str) -> OAuthUserInfo:
        """Get user information from the provider.

        Args:
            access_token: The OAuth access token

        Returns:
            User information

        Raises:
            NotImplementedError: Subclasses must implement this
        """
        raise NotImplementedError


class GoogleOAuthProvider(OAuthProvider):
    """Google OAuth2 provider."""

    name = "google"
    authorize_url = "https://accounts.google.com/o/oauth2/v2/auth"
    token_url = "https://oauth2.googleapis.com/token"
    userinfo_url = "https://www.googleapis.com/oauth2/v2/userinfo"
    scopes: ClassVar[list[str]] = ["openid", "email", "profile"]

    def __init__(self) -> None:
        super().__init__()
        self.client_id = settings.google_client_id
        self.client_secret = settings.google_client_secret

    def get_authorize_url(self, redirect_uri: str, state: str) -> str:
        """Generate Google authorization URL with additional params."""
        params = {
            "client_id": self.client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": " ".join(self.scopes),
            "state": state,
            "access_type": "offline",  # Get refresh token
            "prompt": "select_account",  # Always show account picker
        }
        return f"{self.authorize_url}?{urlencode(params)}"

    async def get_user_info(self, access_token: str) -> OAuthUserInfo:
        """Get user information from Google."""
        async with httpx.AsyncClient() as client:
            response = await client.get(
                self.userinfo_url,
                headers={"Authorization": f"Bearer {access_token}"},
            )
            response.raise_for_status()
            data = response.json()

            return OAuthUserInfo(
                email=data["email"],
                name=data.get("name", data["email"].split("@")[0]),
                provider="google",
                provider_id=data["id"],
                picture=data.get("picture"),
            )


# Provider registry
_providers: dict[str, OAuthProvider] = {
    "google": GoogleOAuthProvider(),
}


def get_provider(name: str) -> OAuthProvider | None:
    """Get an OAuth provider by name.

    Args:
        name: The provider name (google, microsoft, github)

    Returns:
        The provider instance if configured, None otherwise
    """
    provider = _providers.get(name)
    if provider and provider.is_configured:
        return provider
    return None


def get_available_providers() -> list[str]:
    """Get list of configured OAuth providers.

    Returns:
        List of provider names that are properly configured
    """
    return [name for name, provider in _providers.items() if provider.is_configured]


def generate_state() -> str:
    """Generate a secure random state for CSRF protection.

    Returns:
        URL-safe random string
    """
    return secrets.token_urlsafe(32)

