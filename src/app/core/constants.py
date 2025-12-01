"""Application-wide constants.

This module defines constants used throughout the application
to avoid magic numbers and ensure consistency.
"""

# Slug generation
MAX_SLUG_LENGTH = 63

# Hash lengths
SHA256_HEX_LENGTH = 64

# String field lengths
MAX_EMAIL_LENGTH = 255
MAX_NAME_LENGTH = 255
MAX_IPV6_LENGTH = 45
MAX_USER_AGENT_LENGTH = 512
MAX_OAUTH_PROVIDER_LENGTH = 50
MAX_OAUTH_ID_LENGTH = 255
MAX_ROLE_NAME_LENGTH = 100
MAX_PERMISSION_RESOURCE_LENGTH = 100
MAX_PERMISSION_ACTION_LENGTH = 50
MAX_DESCRIPTION_LENGTH = 255

# Password requirements
MIN_PASSWORD_LENGTH = 12
MAX_PASSWORD_LENGTH = 128
BCRYPT_ROUNDS = 12

# Pagination defaults
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100

# Token settings
OAUTH_STATE_TTL_SECONDS = 600  # 10 minutes
ACCESS_TOKEN_JTI_LENGTH = 32

# Secret key requirements
MIN_SECRET_KEY_LENGTH = 32
DEFAULT_INSECURE_SECRET = "change-me-in-production"

