# Entangled Club - Glitch-soc Mastodon Instance

A customized Mastodon instance using Glitch-soc, ready for deployment on Fly.io.

Note that most of the files and config in the repo are for local testing—fly.io has hosted Redis + Postgres solutions, and also only allows you to launch via a Dockerfile, not a docker-compose config. The docker-compose + nginx only exist to reproduce Redis + Postgres (+ SSL termination) locally.

## Local Development with Docker Compose

The easiest way to run Entangled Club locally with HTTPS support:

### Quick Start:

**First time setup:**
```bash
# 1. Copy the example environment file
cp .env.local.example .env.local

# 2. Generate secrets and add them to .env.local
echo "SECRET_KEY_BASE=$(openssl rand -hex 64)"
echo "OTP_SECRET=$(openssl rand -hex 64)"

# 3. Generate VAPID keys and add them to .env.local
docker run --rm ghcr.io/glitch-soc/mastodon:latest bundle exec rails mastodon:webpush:generate_vapid_key

# 4. Generate encryption keys and add them to .env.local
docker run --rm ghcr.io/glitch-soc/mastodon:latest bundle exec rails db:encryption:init

# 4. Start all services
docker-compose up --build
```

**Subsequent runs:**
```bash
docker-compose up --build
```

You can access the instance at https://localhost (you'll just need to accept the cert warning).

### Stop and cleanup:
```bash
docker-compose down
# To also remove data volumes:
docker-compose down -v
```

## Fly.io Deployment

### Prerequisites
Before deploying to fly, you'll want to create new hosted Postgres + Redis clusters and then save their DB urls as secrets.

> [!IMPORTANT]
> Fun fact! Managed Postgres has more limited region options than apps or managed redis through Upstash. Create that first and figure out what region you want, and then deploy your app and Redis correspondingly.

You'll also need to generate and commit the rest of the required secrets:

Generate encryption keys:
```bash
docker run --rm ghcr.io/glitch-soc/mastodon:latest bundle exec rails db:encryption:init
```
Save each of the three keys you get back as secrets in fly (`fly secrets set KEY_NAME=your_key`).

Generate VAPID keys:
```bash
docker run --rm ghcr.io/glitch-soc/mastodon:latest bundle exec rails mastodon:webpush:generate_vapid_key
```

Set all secrets:
```bash
fly secrets set SECRET_KEY_BASE=$(openssl rand -hex 64)
fly secrets set OTP_SECRET=$(openssl rand -hex 64)
fly secrets set VAPID_PRIVATE_KEY=your_generated_private_key
fly secrets set VAPID_PUBLIC_KEY=your_generated_public_key
```

## Environment Variables

### Required for Production
- `DATABASE_URL` - PostgreSQL connection string
- `REDIS_URL` - Redis connection string

### Optional Configuration
- `LOCAL_DOMAIN` - Your instance domain
- `WEB_DOMAIN` - Web interface domain (if different)
- `SINGLE_USER_MODE` - Set to `true` for single-user instance
- `SECRET_KEY_BASE` - Auto-generated if not provided
- `OTP_SECRET` - Auto-generated if not provided
- `VAPID_PRIVATE_KEY` - Auto-generated if not provided
- `VAPID_PUBLIC_KEY` - Auto-generated if not provided
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` - Auto-generated if not provided
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` - Auto-generated if not provided
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` - Auto-generated if not provided
