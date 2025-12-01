# Production Deployment

This guide covers deploying the Agency Standard to production with Docker Compose and Caddy.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                         Internet                             │
└────────────────────────────┬────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│                     Caddy (Reverse Proxy)                    │
│                   - HTTPS termination                        │
│                   - Certificate management                   │
│                   - Request routing                          │
└────────────────────────────┬────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│                    Docker Network (internal)                 │
├──────────────┬──────────────┬──────────────┬────────────────┤
│     App      │    Worker    │   Postgres   │     Redis      │
│  (FastAPI)   │    (ARQ)     │              │                │
└──────────────┴──────────────┴──────────────┴────────────────┘
```

## Production Compose File

```yaml
# deploy/docker-compose.prod.yml
version: "3.9"

services:
  app:
    build:
      context: ..
      dockerfile: deploy/Dockerfile
    restart: unless-stopped
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - REDIS_URL=${REDIS_URL}
      - SECRET_KEY=${SECRET_KEY}
      - ENVIRONMENT=production
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - internal
      - web
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health/live"]
      interval: 30s
      timeout: 5s
      retries: 3

  worker:
    build:
      context: ..
      dockerfile: deploy/Dockerfile
    command: arq app.core.jobs.worker.WorkerSettings
    restart: unless-stopped
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - REDIS_URL=${REDIS_URL}
      - SECRET_KEY=${SECRET_KEY}
      - ENVIRONMENT=production
    depends_on:
      - redis
      - postgres
    networks:
      - internal

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    volumes:
      - postgres_data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: ${DB_USER:-postgres}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME:-agency_standard}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-postgres}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - internal

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - redis_data:/data
    command: redis-server --appendonly yes
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - internal

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - app
    networks:
      - web

volumes:
  postgres_data:
  redis_data:
  caddy_data:
  caddy_config:

networks:
  internal:
    driver: bridge
  web:
    driver: bridge
```

## Caddy Configuration

Caddy handles HTTPS certificates automatically:

```caddyfile
# deploy/Caddyfile
{
    email admin@yourdomain.com
}

api.yourdomain.com {
    reverse_proxy app:8000 {
        health_uri /health/live
        health_interval 30s
    }

    encode gzip

    header {
        # Security headers
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Referrer-Policy strict-origin-when-cross-origin
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        
        # Remove server header
        -Server
    }

    log {
        output stdout
        format json
    }
}
```

## Environment Configuration

Create a `.env.prod` file:

```bash
# .env.prod

# Application
SECRET_KEY=your-production-secret-key  # Generate with: just secret
ENVIRONMENT=production
DEBUG=false
LOG_LEVEL=INFO

# Database
DATABASE_URL=postgresql+asyncpg://postgres:your-db-password@postgres:5432/agency_standard
DB_USER=postgres
DB_PASSWORD=your-db-password
DB_NAME=agency_standard

# Redis
REDIS_URL=redis://redis:6379

# Optional: OAuth providers
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=

# Optional: Observability
OTLP_ENDPOINT=
```

!!! warning "Security"
    Never commit `.env.prod` to version control. Use secrets management in CI/CD.

## Deployment Steps

### 1. Prepare Server

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh

# Install Docker Compose
sudo apt install docker-compose-plugin

# Create deployment directory
mkdir -p /opt/agency-standard
cd /opt/agency-standard
```

### 2. Clone Repository

```bash
git clone https://github.com/your-org/agency-standard.git .
```

### 3. Configure Environment

```bash
cp .env.example .env.prod
# Edit .env.prod with production values
```

### 4. Build and Start

```bash
# Build images
docker compose -f deploy/docker-compose.prod.yml build

# Start services
docker compose -f deploy/docker-compose.prod.yml up -d

# Run migrations
docker compose -f deploy/docker-compose.prod.yml exec app alembic upgrade head
```

### 5. Verify Deployment

```bash
# Check service health
docker compose -f deploy/docker-compose.prod.yml ps

# Check logs
docker compose -f deploy/docker-compose.prod.yml logs app

# Test endpoints
curl https://api.yourdomain.com/health/live
curl https://api.yourdomain.com/health/ready
```

## Updates and Rollbacks

### Deploying Updates

```bash
# Pull latest code
git pull origin main

# Rebuild and restart
docker compose -f deploy/docker-compose.prod.yml build app worker
docker compose -f deploy/docker-compose.prod.yml up -d app worker

# Run any new migrations
docker compose -f deploy/docker-compose.prod.yml exec app alembic upgrade head
```

### Rolling Back

```bash
# Rollback to previous commit
git checkout HEAD~1

# Rebuild and restart
docker compose -f deploy/docker-compose.prod.yml build app worker
docker compose -f deploy/docker-compose.prod.yml up -d app worker

# Rollback migrations if needed
docker compose -f deploy/docker-compose.prod.yml exec app alembic downgrade -1
```

## Scaling

### Horizontal Scaling

Scale the app containers:

```bash
docker compose -f deploy/docker-compose.prod.yml up -d --scale app=3
```

Caddy will automatically load balance between instances.

### Vertical Scaling

Add resource limits in docker-compose:

```yaml
services:
  app:
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 2G
        reservations:
          cpus: "0.5"
          memory: 512M
```

## Monitoring

### Health Checks

| Endpoint | Purpose |
|----------|---------|
| `/health/live` | Is the process running? |
| `/health/ready` | Can we serve traffic? |

### Logs

```bash
# View all logs
docker compose -f deploy/docker-compose.prod.yml logs -f

# View specific service
docker compose -f deploy/docker-compose.prod.yml logs -f app

# View last 100 lines
docker compose -f deploy/docker-compose.prod.yml logs --tail=100 app
```

### Metrics (Optional)

If OpenTelemetry is configured, metrics are exported to your OTLP endpoint:

```bash
# .env.prod
OTLP_ENDPOINT=https://otel-collector.yourdomain.com:4317
```

## Backup and Recovery

### Database Backup

```bash
# Create backup
docker compose -f deploy/docker-compose.prod.yml exec postgres \
  pg_dump -U postgres agency_standard > backup_$(date +%Y%m%d).sql

# Restore backup
docker compose -f deploy/docker-compose.prod.yml exec -T postgres \
  psql -U postgres agency_standard < backup_20240115.sql
```

### Automated Backups

Add a backup service to docker-compose:

```yaml
backup:
  image: prodrigestivill/postgres-backup-local
  restart: unless-stopped
  volumes:
    - ./backups:/backups
  environment:
    - POSTGRES_HOST=postgres
    - POSTGRES_DB=agency_standard
    - POSTGRES_USER=postgres
    - POSTGRES_PASSWORD=${DB_PASSWORD}
    - SCHEDULE=@daily
    - BACKUP_KEEP_DAYS=7
  networks:
    - internal
```

## Security Checklist

- [ ] Strong `SECRET_KEY` generated and set
- [ ] Database password is strong and unique
- [ ] `.env.prod` is not in version control
- [ ] HTTPS is enforced (Caddy handles this)
- [ ] Security headers are set in Caddy
- [ ] API docs disabled in production (`ENVIRONMENT=production`)
- [ ] Firewall allows only ports 80 and 443
- [ ] Regular backups are configured
- [ ] Log aggregation is set up
- [ ] Monitoring and alerts are configured

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker compose -f deploy/docker-compose.prod.yml logs app

# Check health
docker compose -f deploy/docker-compose.prod.yml ps
```

### Database Connection Issues

```bash
# Verify database is healthy
docker compose -f deploy/docker-compose.prod.yml exec postgres pg_isready

# Check connection from app
docker compose -f deploy/docker-compose.prod.yml exec app \
  python -c "from app.core.database import engine; print('OK')"
```

### SSL Certificate Issues

Caddy handles certificates automatically. If there are issues:

```bash
# Check Caddy logs
docker compose -f deploy/docker-compose.prod.yml logs caddy

# Verify DNS points to your server
dig api.yourdomain.com
```

## Next Steps

- [Docker Setup](docker.md) - Development Docker setup
- [Architecture](../architecture/overview.md) - System design
- [API Overview](../api/overview.md) - API documentation

