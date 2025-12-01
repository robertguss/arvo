# API Overview

The Agency Standard API follows REST conventions with strict standards for consistency and discoverability.

## Base URL

```
http://localhost:8000/api/v1
```

In production, this would be:

```
https://api.yourdomain.com/api/v1
```

## API Documentation

Interactive documentation is available in development:

- **Swagger UI**: [http://localhost:8000/docs](http://localhost:8000/docs)
- **ReDoc**: [http://localhost:8000/redoc](http://localhost:8000/redoc)
- **OpenAPI JSON**: [http://localhost:8000/openapi.json](http://localhost:8000/openapi.json)

!!! note "Production"
    API documentation is disabled in production by default. Set `ENVIRONMENT=development` to enable.

## Endpoint Requirements

All endpoints must have these attributes:

| Attribute | Purpose | Example |
|-----------|---------|---------|
| `response_model` | Pydantic schema for response | `response_model=UserResponse` |
| `summary` | Brief description for OpenAPI | `summary="Create a new user"` |
| `tags` | Categorization for docs | `tags=["users"]` |
| `status_code` | HTTP status on success | `status_code=201` |

```python
@router.post(
    "/users",
    response_model=UserResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create a new user",
    tags=["users"],
)
async def create_user(data: UserCreate) -> UserResponse:
    """Create a new user in the current tenant.
    
    This endpoint requires authentication and creates a user
    associated with the authenticated user's tenant.
    """
    ...
```

## HTTP Methods

| Method | Purpose | Idempotent | Success Code |
|--------|---------|------------|--------------|
| `GET` | Retrieve resource(s) | Yes | 200 |
| `POST` | Create resource | No | 201 |
| `PUT` | Replace resource | Yes | 200 |
| `PATCH` | Partial update | No | 200 |
| `DELETE` | Remove resource | Yes | 204 |

## Request Headers

### Required Headers

| Header | Value | Purpose |
|--------|-------|---------|
| `Authorization` | `Bearer <token>` | JWT authentication |
| `Content-Type` | `application/json` | Request body format |

### Optional Headers

| Header | Value | Purpose |
|--------|-------|---------|
| `X-Request-ID` | UUID | Request tracing (auto-generated if missing) |
| `Accept-Language` | `en-US` | Localization (future) |

## Response Format

### Success Response

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "Example Item",
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:30:00Z"
}
```

### List Response

```json
{
  "items": [
    {"id": "...", "name": "Item 1"},
    {"id": "...", "name": "Item 2"}
  ],
  "total": 42,
  "page": 1,
  "page_size": 20,
  "pages": 3,
  "has_next": true,
  "has_prev": false
}
```

### Error Response (RFC 7807)

All errors follow the RFC 7807 Problem Details format:

```json
{
  "type": "https://api.example.com/errors/not-found",
  "title": "Not Found",
  "status": 404,
  "detail": "User with ID '123' not found",
  "instance": "/api/v1/users/123",
  "trace_id": "abc123def456"
}
```

See [Error Handling](errors.md) for details.

## Pagination

List endpoints support pagination:

```
GET /api/v1/items?page=1&page_size=20
```

| Parameter | Default | Max | Description |
|-----------|---------|-----|-------------|
| `page` | 1 | - | Page number (1-indexed) |
| `page_size` | 20 | 100 | Items per page |

### Pagination Response Schema

```python
class PaginatedResponse(BaseModel, Generic[T]):
    items: list[T]
    total: int
    page: int
    page_size: int
    pages: int
    has_next: bool
    has_prev: bool
```

## Filtering

List endpoints may support filtering:

```
GET /api/v1/items?status=active&created_after=2024-01-01
```

Filter parameters are endpoint-specific. Check the OpenAPI docs for available filters.

## Sorting

Some endpoints support sorting:

```
GET /api/v1/items?sort_by=created_at&sort_order=desc
```

| Parameter | Values | Default |
|-----------|--------|---------|
| `sort_by` | Field name | `created_at` |
| `sort_order` | `asc`, `desc` | `desc` |

## Versioning

The API uses URL path versioning:

```
/api/v1/users
/api/v2/users  (future)
```

### Deprecation

Deprecated endpoints include headers:

```http
Deprecation: true
Sunset: 2025-12-31
Link: </api/v2/users>; rel="successor-version"
```

## Rate Limiting

Requests are rate-limited per user/tenant:

```http
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 95
X-RateLimit-Reset: 1699999999
```

When exceeded:

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 30
```

See configuration for tier-based limits.

## Health Endpoints

| Endpoint | Purpose | Auth Required |
|----------|---------|---------------|
| `/health/live` | Liveness probe | No |
| `/health/ready` | Readiness probe | No |

```bash
# Liveness (is the process running?)
curl http://localhost:8000/health/live
# {"status": "alive"}

# Readiness (can we serve traffic?)
curl http://localhost:8000/health/ready
# {"status": "ready", "checks": {"database": "ok", "redis": "ok"}}
```

## Common Patterns

### Creating Resources

```bash
curl -X POST http://localhost:8000/api/v1/items \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "New Item"}'
```

Response: `201 Created`

### Updating Resources

```bash
curl -X PATCH http://localhost:8000/api/v1/items/123 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Updated Name"}'
```

Response: `200 OK`

### Deleting Resources

```bash
curl -X DELETE http://localhost:8000/api/v1/items/123 \
  -H "Authorization: Bearer $TOKEN"
```

Response: `204 No Content`

## Next Steps

- [Authentication](authentication.md) - JWT and OAuth2
- [Error Handling](errors.md) - RFC 7807 error format
- [Architecture](../architecture/overview.md) - System design

