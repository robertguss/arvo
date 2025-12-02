# Authentication

The Agency Standard supports multiple authentication methods: JWT tokens, HTTP-only cookie sessions, and OAuth2 providers.

## Authentication Methods

| Method           | Use Case                 | Token Location         |
| ---------------- | ------------------------ | ---------------------- |
| JWT Bearer       | API clients, mobile apps | `Authorization` header |
| HTTP-Only Cookie | Browser-based apps       | Cookie                 |
| OAuth2           | Social login             | Redirects              |

## JWT Authentication

### Token Structure

**Access Token:**

- Short-lived (15 minutes default)
- Contains user ID, tenant ID, roles
- Sent in `Authorization` header

**Refresh Token:**

- Long-lived (7 days default)
- HTTP-only cookie
- Used to obtain new access tokens

### Login Flow

```bash
# 1. Login with credentials
curl -X POST http://localhost:8000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "user@example.com", "password": "secret"}'
```

Response:

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIs...",
  "token_type": "bearer",
  "expires_in": 900
}
```

The refresh token is set as an HTTP-only cookie.

### Using Access Tokens

```bash
# Include token in Authorization header
curl http://localhost:8000/api/v1/users/me \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIs..."
```

### Refreshing Tokens

```bash
# Refresh token is sent automatically via cookie
curl -X POST http://localhost:8000/api/v1/auth/refresh \
  --cookie "refresh_token=..."
```

Response:

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIs...",
  "token_type": "bearer",
  "expires_in": 900
}
```

### Logout

```bash
curl -X POST http://localhost:8000/api/v1/auth/logout \
  -H "Authorization: Bearer $TOKEN"
```

This invalidates the refresh token.

## OAuth2 Authentication

### Supported Providers

| Provider  | Environment Variables                            |
| --------- | ------------------------------------------------ |
| Google    | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`       |
| Microsoft | `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET` |
| GitHub    | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`       |

### OAuth2 Flow

```
1. Client → /auth/oauth/{provider}/authorize
2. User authenticates with provider
3. Provider → /auth/oauth/{provider}/callback
4. Server creates/links user account
5. Server issues JWT tokens
6. Client receives tokens
```

### Initiating OAuth2

```bash
# Redirect user to this URL
GET /api/v1/auth/oauth/google/authorize?redirect_uri=https://app.example.com/callback
```

The server redirects to Google's OAuth consent screen.

### OAuth2 Callback

After user authenticates, Google redirects to:

```
/api/v1/auth/oauth/google/callback?code=...&state=...
```

The server:

1. Exchanges code for user info
2. Creates or links user account
3. Issues JWT tokens
4. Redirects to your app with tokens

## Protecting Endpoints

### Require Authentication

```python
from typing import Annotated
from fastapi import Depends

from app.core.auth import get_current_user
from app.modules.users.models import User


@router.get("/profile")
async def get_profile(
    current_user: Annotated[User, Depends(get_current_user)],
):
    """Requires authentication."""
    return {"user_id": current_user.id}
```

### Optional Authentication

```python
from app.core.auth import get_current_user_optional


@router.get("/items")
async def list_items(
    current_user: Annotated[User | None, Depends(get_current_user_optional)],
):
    """Works with or without authentication."""
    if current_user:
        # Return user's items
        ...
    else:
        # Return public items
        ...
```

## Permissions (RBAC) {#permissions}

### Permission Model

```
User → UserRole → Role → RolePermission → Permission
```

Permissions are defined as `resource:action` pairs:

- `users:read` - Read user data
- `users:write` - Create/update users
- `users:delete` - Delete users
- `admin:*` - All admin permissions

### Checking Permissions

```python
from app.core.permissions import require_permission


@router.delete("/users/{user_id}")
@require_permission("users", "delete")
async def delete_user(
    user_id: UUID,
    current_user: Annotated[User, Depends(get_current_user)],
):
    """Requires 'users:delete' permission."""
    ...
```

### Permission Decorator

The `@require_permission` decorator:

1. Gets the current user
2. Loads user's roles and permissions
3. Checks if any role has the required permission
4. Raises 403 Forbidden if not authorized

```python
def require_permission(resource: str, action: str):
    """Decorator to require a specific permission."""
    async def permission_checker(
        current_user: Annotated[User, Depends(get_current_user)],
        checker: Annotated[PermissionChecker, Depends()],
    ):
        if not await checker.has_permission(current_user, resource, action):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Permission denied: {resource}:{action}",
            )
    return Depends(permission_checker)
```

### Default Roles

| Role     | Permissions              |
| -------- | ------------------------ |
| `admin`  | All permissions          |
| `member` | Read/write own resources |
| `viewer` | Read-only access         |

## Configuration

```bash
# .env
SECRET_KEY=your-secret-key-here  # Generate with: just secret

# Token expiry
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=7

# OAuth2 providers (optional)
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
MICROSOFT_CLIENT_ID=...
MICROSOFT_CLIENT_SECRET=...
GITHUB_CLIENT_ID=...
GITHUB_CLIENT_SECRET=...
```

## Security Best Practices

### Token Security

- ✅ Use short-lived access tokens (15 min)
- ✅ Store refresh tokens in HTTP-only cookies
- ✅ Rotate refresh tokens on use
- ✅ Use secure cookies in production

### Password Security

- ✅ Passwords hashed with bcrypt
- ✅ Minimum password length enforced
- ✅ Rate limiting on login attempts

### OAuth2 Security

- ✅ State parameter prevents CSRF
- ✅ PKCE for public clients
- ✅ Validate redirect URIs

## Error Responses

| Status | Meaning                                  |
| ------ | ---------------------------------------- |
| 401    | Missing or invalid token                 |
| 403    | Valid token but insufficient permissions |

```json
{
  "type": "https://api.example.com/errors/unauthorized",
  "title": "Unauthorized",
  "status": 401,
  "detail": "Invalid or expired token",
  "trace_id": "abc123"
}
```

## Testing Authentication

```python
import pytest
from httpx import AsyncClient


@pytest.fixture
async def auth_headers(client: AsyncClient, user: User) -> dict:
    """Get authentication headers for a test user."""
    from app.core.auth import create_access_token

    token = create_access_token(user)
    return {"Authorization": f"Bearer {token}"}


async def test_protected_endpoint(client: AsyncClient, auth_headers: dict):
    response = await client.get("/api/v1/users/me", headers=auth_headers)
    assert response.status_code == 200
```

## Next Steps

- [Error Handling](errors.md) - RFC 7807 error format
- [API Overview](overview.md) - API conventions
- [Multi-Tenancy](../architecture/multi-tenancy.md) - Tenant context
