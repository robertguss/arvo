# Error Handling

The Agency Standard uses [RFC 7807 Problem Details](https://datatracker.ietf.org/doc/html/rfc7807) for all error responses. This provides a consistent, machine-readable error format.

## Error Response Format

Every error response follows this structure:

```json
{
  "type": "https://api.example.com/errors/not-found",
  "title": "Not Found",
  "status": 404,
  "detail": "User with ID '550e8400-e29b-41d4-a716-446655440000' not found",
  "instance": "/api/v1/users/550e8400-e29b-41d4-a716-446655440000",
  "trace_id": "abc123def456"
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `type` | URI | Error type identifier (link to documentation) |
| `title` | string | Human-readable error title |
| `status` | integer | HTTP status code |
| `detail` | string | Specific error message |
| `instance` | string | Request path that caused the error |
| `trace_id` | string | Request trace ID for debugging |
| `errors` | array | Field-level errors (validation only) |

## Common Error Types

### 400 Bad Request

Invalid request syntax or parameters.

```json
{
  "type": "https://api.example.com/errors/bad-request",
  "title": "Bad Request",
  "status": 400,
  "detail": "Invalid JSON in request body",
  "instance": "/api/v1/users",
  "trace_id": "abc123"
}
```

### 401 Unauthorized

Missing or invalid authentication.

```json
{
  "type": "https://api.example.com/errors/unauthorized",
  "title": "Unauthorized",
  "status": 401,
  "detail": "Invalid or expired access token",
  "instance": "/api/v1/users/me",
  "trace_id": "abc123"
}
```

### 403 Forbidden

Authenticated but lacking permissions.

```json
{
  "type": "https://api.example.com/errors/forbidden",
  "title": "Forbidden",
  "status": 403,
  "detail": "Permission denied: users:delete",
  "instance": "/api/v1/users/123",
  "trace_id": "abc123"
}
```

### 404 Not Found

Resource doesn't exist.

```json
{
  "type": "https://api.example.com/errors/not-found",
  "title": "Not Found",
  "status": 404,
  "detail": "User not found",
  "instance": "/api/v1/users/123",
  "trace_id": "abc123"
}
```

### 409 Conflict

Resource conflict (e.g., duplicate).

```json
{
  "type": "https://api.example.com/errors/conflict",
  "title": "Conflict",
  "status": 409,
  "detail": "User with email 'john@example.com' already exists",
  "instance": "/api/v1/users",
  "trace_id": "abc123"
}
```

### 422 Validation Error

Request validation failed.

```json
{
  "type": "https://api.example.com/errors/validation",
  "title": "Validation Error",
  "status": 422,
  "detail": "Request validation failed",
  "instance": "/api/v1/users",
  "trace_id": "abc123",
  "errors": [
    {
      "field": ["body", "email"],
      "message": "Invalid email format"
    },
    {
      "field": ["body", "password"],
      "message": "Password must be at least 8 characters"
    }
  ]
}
```

### 429 Rate Limited

Too many requests.

```json
{
  "type": "https://api.example.com/errors/rate-limited",
  "title": "Too Many Requests",
  "status": 429,
  "detail": "Rate limit exceeded. Retry after 30 seconds.",
  "instance": "/api/v1/users",
  "trace_id": "abc123"
}
```

Headers:

```http
Retry-After: 30
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1699999999
```

### 500 Internal Server Error

Unexpected server error.

```json
{
  "type": "https://api.example.com/errors/internal",
  "title": "Internal Server Error",
  "status": 500,
  "detail": "An unexpected error occurred. Please try again later.",
  "instance": "/api/v1/users",
  "trace_id": "abc123"
}
```

!!! note "Error Details"
    In production, internal error details are hidden. Use the `trace_id` to find details in logs.

## Raising Errors

### Using HTTPException

For simple errors, use FastAPI's `HTTPException`:

```python
from fastapi import HTTPException, status

async def get_user(user_id: UUID) -> User:
    user = await repo.get(user_id)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )
    return user
```

### Custom Domain Exceptions

For domain-specific errors, define custom exceptions:

```python
# src/app/core/errors/exceptions.py
from fastapi import status


class DomainError(Exception):
    """Base class for domain errors."""
    status_code: int = status.HTTP_400_BAD_REQUEST
    error_type: str = "domain-error"
    title: str = "Domain Error"

    def __init__(self, detail: str):
        self.detail = detail
        super().__init__(detail)


class NotFoundError(DomainError):
    """Resource not found."""
    status_code = status.HTTP_404_NOT_FOUND
    error_type = "not-found"
    title = "Not Found"


class ConflictError(DomainError):
    """Resource conflict."""
    status_code = status.HTTP_409_CONFLICT
    error_type = "conflict"
    title = "Conflict"


class PermissionDeniedError(DomainError):
    """Permission denied."""
    status_code = status.HTTP_403_FORBIDDEN
    error_type = "forbidden"
    title = "Forbidden"
```

Usage:

```python
from app.core.errors import NotFoundError, ConflictError

class UserService:
    async def get(self, user_id: UUID) -> User:
        user = await self.repo.get(user_id)
        if not user:
            raise NotFoundError(f"User with ID '{user_id}' not found")
        return user

    async def create(self, data: UserCreate) -> User:
        existing = await self.repo.get_by_email(data.email)
        if existing:
            raise ConflictError(f"User with email '{data.email}' already exists")
        return await self.repo.create(User(**data.model_dump()))
```

## Exception Handlers

Exception handlers convert exceptions to RFC 7807 responses:

```python
# src/app/core/errors/handlers.py
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel


class ProblemDetail(BaseModel):
    type: str
    title: str
    status: int
    detail: str
    instance: str | None = None
    trace_id: str | None = None
    errors: list[dict] | None = None


def register_exception_handlers(app: FastAPI) -> None:
    """Register all exception handlers."""

    @app.exception_handler(DomainError)
    async def domain_error_handler(request: Request, exc: DomainError):
        return JSONResponse(
            status_code=exc.status_code,
            content=ProblemDetail(
                type=f"https://api.example.com/errors/{exc.error_type}",
                title=exc.title,
                status=exc.status_code,
                detail=exc.detail,
                instance=str(request.url.path),
                trace_id=getattr(request.state, "request_id", None),
            ).model_dump(),
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(request: Request, exc: RequestValidationError):
        return JSONResponse(
            status_code=422,
            content=ProblemDetail(
                type="https://api.example.com/errors/validation",
                title="Validation Error",
                status=422,
                detail="Request validation failed",
                instance=str(request.url.path),
                trace_id=getattr(request.state, "request_id", None),
                errors=[
                    {"field": e["loc"], "message": e["msg"]}
                    for e in exc.errors()
                ],
            ).model_dump(),
        )
```

## Trace IDs

Every request has a trace ID for debugging:

1. Check `X-Request-ID` header (use if provided)
2. Generate UUID if not provided
3. Include in all logs and error responses
4. Return in response headers

```python
class RequestIdMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get("X-Request-ID") or str(uuid4())
        request.state.request_id = request_id
        
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        
        return response
```

## Client Error Handling

### JavaScript/TypeScript

```typescript
interface ProblemDetail {
  type: string;
  title: string;
  status: number;
  detail: string;
  instance?: string;
  trace_id?: string;
  errors?: Array<{ field: string[]; message: string }>;
}

async function apiCall(url: string): Promise<Response> {
  const response = await fetch(url);
  
  if (!response.ok) {
    const problem: ProblemDetail = await response.json();
    
    switch (problem.status) {
      case 401:
        // Redirect to login
        break;
      case 403:
        // Show permission denied
        break;
      case 422:
        // Show validation errors
        console.error("Validation errors:", problem.errors);
        break;
      default:
        // Show generic error with trace_id
        console.error(`Error ${problem.trace_id}: ${problem.detail}`);
    }
    
    throw new Error(problem.detail);
  }
  
  return response;
}
```

### Python

```python
import httpx

async def api_call(url: str) -> dict:
    async with httpx.AsyncClient() as client:
        response = await client.get(url)
        
        if not response.is_success:
            problem = response.json()
            
            if problem["status"] == 422:
                # Handle validation errors
                for error in problem.get("errors", []):
                    print(f"Field {error['field']}: {error['message']}")
            
            raise Exception(f"API Error [{problem['trace_id']}]: {problem['detail']}")
        
        return response.json()
```

## Best Practices

### Be Specific in Error Messages

```python
# ✅ Good - specific message
raise NotFoundError(f"User with ID '{user_id}' not found")

# ❌ Bad - generic message
raise NotFoundError("Not found")
```

### Use Appropriate Status Codes

```python
# ✅ Good - 409 for duplicates
raise ConflictError("Email already registered")

# ❌ Bad - using 400 for everything
raise HTTPException(status_code=400, detail="Email exists")
```

### Include Context for Debugging

```python
# ✅ Good - log context before raising
logger.warning("user_not_found", user_id=str(user_id), tenant_id=str(tenant_id))
raise NotFoundError(f"User with ID '{user_id}' not found")
```

### Don't Expose Sensitive Data

```python
# ✅ Good - hide internal details in production
if settings.is_production:
    raise HTTPException(status_code=500, detail="Internal server error")
else:
    raise HTTPException(status_code=500, detail=str(exception))
```

## Next Steps

- [API Overview](overview.md) - API conventions
- [Authentication](authentication.md) - Auth and permissions
- [Architecture](../architecture/overview.md) - System design

