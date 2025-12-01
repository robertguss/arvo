"""Text processing utilities."""

import re

from app.core.constants import MAX_SLUG_LENGTH


def generate_slug(name: str, max_length: int = MAX_SLUG_LENGTH) -> str:
    """Generate a URL-safe slug from a name.

    Converts the input string to a URL-friendly slug by:
    - Converting to lowercase
    - Removing special characters
    - Replacing spaces and hyphens with single hyphens
    - Truncating to max_length

    Args:
        name: The input string to slugify
        max_length: Maximum length of output slug (default 63)

    Returns:
        URL-safe lowercase slug

    Examples:
        >>> generate_slug("My Company Name")
        'my-company-name'
        >>> generate_slug("Hello! World@2024")
        'hello-world2024'
    """
    slug = name.lower().strip()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"[-\s]+", "-", slug)
    return slug[:max_length]

