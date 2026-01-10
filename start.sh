#!/bin/bash
set -e

# Check if we're running in local development mode
LOCAL_TEST_MODE=false
if [ "$LOCAL_DEV" = "true" ]; then
  echo "🧪 Running in local development mode - skipping database dependency checks"
  LOCAL_TEST_MODE=true

  # Allow Rails to auto-load .env.local in local development
  if [ -f "/opt/mastodon/.env.local" ]; then
    echo "🔧 Loading local environment variables from .env.local"
    # Rails will auto-load it via dotenv gem
  fi
else
  # Prevent Rails from auto-loading .env.local in production
  export DOTENV_SKIP_LOAD=true
fi

# Ensure we have required configuration (unless in local test mode)
if [ "$LOCAL_TEST_MODE" = false ]; then
  if [ -z "$DATABASE_URL" ]; then
    echo "❌ Error: DATABASE_URL is required"
    echo "Example: DATABASE_URL=postgresql://user:pass@host:5432/dbname"
    exit 1
  fi

  if [ -z "$REDIS_URL" ]; then
    echo "❌ Error: REDIS_URL is required"
    echo "Example: REDIS_URL=redis://host:6379"
    exit 1
  fi
fi

# Check for required secrets
echo "🔐 Checking secrets configuration..."

# List of required secrets
REQUIRED_SECRETS="SECRET_KEY_BASE OTP_SECRET VAPID_PRIVATE_KEY VAPID_PUBLIC_KEY"
MISSING_SECRETS=""

for secret in $REQUIRED_SECRETS; do
  if [ -z "$(eval echo \$$secret)" ]; then
    MISSING_SECRETS="$MISSING_SECRETS $secret"
  fi
done

if [ -n "$MISSING_SECRETS" ]; then
  echo "❌ Missing required secrets:$MISSING_SECRETS"
  echo ""
  if [ -n "$FLY_APP_NAME" ]; then
    echo "Running on Fly.io. Set secrets using:"
    echo "  fly secrets set SECRET_KEY_BASE=\$(openssl rand -hex 64)"
    echo "  fly secrets set OTP_SECRET=\$(openssl rand -hex 64)"
    echo "  # Generate VAPID keys with: bundle exec rails mastodon:webpush:generate_vapid_key"
    echo "  fly secrets set VAPID_PRIVATE_KEY=your_private_key"
    echo "  fly secrets set VAPID_PUBLIC_KEY=your_public_key"
  else
    echo "Running locally. Create .env.local file with secrets:"
    echo "  cp .env.local.example .env.local"
    echo "  # Then edit .env.local with your generated secrets"
    echo "  # See README.md for detailed instructions"
  fi
  echo ""
  exit 1
fi

echo "✅ All required secrets are configured"

# Skip database setup in local test mode
if [ "$LOCAL_TEST_MODE" = false ]; then
  # Wait for database to be ready
  echo "⏳ Waiting for database..."
  until psql $DATABASE_URL -c "SELECT 1" >/dev/null 2>&1; do
    echo "Database not ready, waiting..."
    sleep 2
  done
  echo "✅ Database is ready"

  # Run database setup using direct SQL queries
  echo "🗄️ Setting up database..."

  # Create database if it doesn't exist
  psql $(echo $DATABASE_URL | sed 's|/[^/]*$|/postgres|') -c "CREATE DATABASE $(echo $DATABASE_URL | sed 's|.*/||') WITH OWNER $(echo $DATABASE_URL | sed 's|.*://\([^:]*\):.*|\1|');" 2>/dev/null || echo "Database already exists"

  # Check if schema_migrations table exists (indicates Rails has been set up)
  echo "🔍 Checking if Rails schema is initialized..."
  SCHEMA_MIGRATIONS_EXISTS=$(psql $DATABASE_URL -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'schema_migrations');" 2>/dev/null | tr -d ' ' || echo "f")

  echo "🔍 Schema migrations table exists: $SCHEMA_MIGRATIONS_EXISTS"

  if [ "$SCHEMA_MIGRATIONS_EXISTS" = "f" ]; then
    echo "📋 Rails schema not initialized, loading schema..."
    # Only use Rails for schema loading since it's complex
    timeout 300 bundle exec rails db:schema:load || {
      echo "❌ Schema load timed out or failed"
      exit 1
    }
    echo "🌱 Running initial seed data..."
    timeout 300 bundle exec rails db:seed || {
      echo "⚠️ Seed data failed, continuing anyway..."
    }
  else
    echo "🔄 Rails schema exists, running migrations..."
    # Only use Rails for migrations since they're complex
    timeout 300 bundle exec rails db:migrate || {
      echo "❌ Migration timed out or failed"
      exit 1
    }
  fi

  echo "✅ Database setup complete"

  # Test database connection directly
  echo "🔗 Testing database connection..."
  if psql $DATABASE_URL -c "SELECT 1;" >/dev/null 2>&1; then
    echo "✅ Database connection works"
  else
    echo "❌ Database connection failed, but continuing anyway..."
  fi
else
  echo "🧪 Skipping database setup in local test mode"
fi

# Precompile assets if they do not exist
if [ ! -d "public/assets" ] || [ -z "$(ls -A public/assets 2>/dev/null)" ]; then
  echo "🎨 Precompiling assets..."
  bundle exec rails assets:precompile
  echo "✅ Assets precompiled"
fi

# Test if bundle exec works at all
echo "🧪 Testing bundle exec functionality..."
if timeout 30 bundle exec ruby -e "puts 'Bundle exec works'" 2>/dev/null; then
  echo "✅ Bundle exec is working"
else
  echo "❌ Bundle exec is hanging or broken - this will cause issues"
  echo "🔍 Checking Ruby/Bundler environment..."
  echo "Ruby version: $(ruby -v)"
  echo "Bundler version: $(bundle -v)"
  echo "Gem environment:"
  gem env | head -10
  echo "⚠️ Continuing anyway, but expect issues..."
fi

# Start web server, Sidekiq, and streaming server
echo "🚀 Starting Mastodon services..."

# Determine the correct URLs based on environment
if [ -n "$FLY_APP_NAME" ]; then
  # Running on Fly.io
  echo "🌐 Instance domain: ${LOCAL_DOMAIN:-$FLY_APP_NAME.fly.dev}"
  echo "📍 Public URL: https://${LOCAL_DOMAIN:-$FLY_APP_NAME.fly.dev}"
  echo "🛩️ Running on Fly.io (app: $FLY_APP_NAME)"
else
  # Running locally
  echo "🌐 Local domain: ${LOCAL_DOMAIN:-localhost}"
  echo "📍 Direct access: http://0.0.0.0:3000"
  echo "🏠 Running locally"
fi

echo ""

# Start Sidekiq in background (skip in local test mode)
if [ "$LOCAL_TEST_MODE" = false ]; then
  echo "🔄 Starting Sidekiq background workers..."
  bundle exec sidekiq &
  SIDEKIQ_PID=$!

  # Give Sidekiq a moment to start
  sleep 3

  # Check if Sidekiq started successfully
  if kill -0 $SIDEKIQ_PID 2>/dev/null; then
    echo "✅ Sidekiq started successfully (PID: $SIDEKIQ_PID)"
  else
    echo "❌ Sidekiq failed to start, continuing with web server only..."
    SIDEKIQ_PID=""
  fi
else
  echo "🧪 Skipping Sidekiq in local test mode"
  SIDEKIQ_PID=""
fi

# Start streaming server in background (skip in local test mode)
if [ "$LOCAL_TEST_MODE" = false ]; then
  echo "🌊 Starting streaming server..."
  PORT=4000 STREAMING_CLUSTER_NUM=1 node streaming/index.js &
  STREAMING_PID=$!

  # Give streaming server a moment to start
  sleep 3

  # Check if streaming server started successfully
  if kill -0 $STREAMING_PID 2>/dev/null; then
    echo "✅ Streaming server started successfully (PID: $STREAMING_PID)"
  else
    echo "❌ Streaming server failed to start, continuing without streaming..."
    STREAMING_PID=""
  fi
else
  echo "🧪 Skipping streaming server in local test mode"
  STREAMING_PID=""
fi

# Start web server in background
echo "🔄 Starting web server..."
bundle exec rails server -b 127.0.0.1 -p 3000 &
WEB_PID=$!

# Give web server a moment to start
sleep 3

# Check if web server started successfully
if kill -0 $WEB_PID 2>/dev/null; then
  echo "✅ Web server started successfully (PID: $WEB_PID)"
else
  echo "❌ Web server failed to start, exiting..."
  [ -n "$SIDEKIQ_PID" ] && kill $SIDEKIQ_PID 2>/dev/null
  [ -n "$STREAMING_PID" ] && kill $STREAMING_PID 2>/dev/null
  exit 1
fi

# Wait for Rails to be ready before starting nginx
echo "🔍 Waiting for Rails to be ready..."
RAILS_READY=false
for i in {1..30}; do
  if curl -s http://127.0.0.1:3000/health >/dev/null 2>&1; then
    echo "✅ Rails is responding on port 3000"
    RAILS_READY=true
    break
  fi
  echo "Rails not ready, waiting... ($i/30)"
  sleep 2
done

if [ "$RAILS_READY" = false ]; then
  echo "❌ Rails failed to become ready, continuing anyway..."
fi

# Wait for streaming to be ready before starting nginx
echo "🔍 Waiting for streaming server to be ready..."
STREAMING_READY=false
for i in {1..30}; do
  if curl -s http://127.0.0.1:4000 >/dev/null 2>&1; then
    echo "✅ Streaming server is responding on port 4000"
    STREAMING_READY=true
    break
  fi
  echo "Streaming not ready, waiting... ($i/30)"
  sleep 2
done

if [ "$STREAMING_READY" = false ]; then
  echo "❌ Streaming server failed to become ready, continuing anyway..."
fi

if [ "$LOCAL_TEST_MODE" = "true" ]; then
  echo "🧪 Local test mode - will start nginx for production-like testing"
fi

# Start nginx (both local and production)
echo "🌐 Starting nginx reverse proxy..."

# Kill any existing nginx processes first
pkill nginx 2>/dev/null || true
sleep 1

# Start nginx
nginx

# Give nginx a moment to start
sleep 2

# Check if nginx is actually running by checking if it's listening on port 8080
if ss -tlnp | grep -q ":8080 "; then
  NGINX_PID=$(pgrep -f "nginx: master process" || echo "unknown")
  echo "✅ Nginx started successfully (PID: $NGINX_PID)"
else
  echo "❌ Nginx failed to start, debugging..."
  echo "🔍 Checking nginx configuration..."
  nginx -t
  echo "🔍 Checking nginx error log..."
  tail -20 /var/log/nginx/error.log 2>/dev/null || echo "No error log found"
  echo "🔍 Checking what's using port 8080..."
  ss -tlnp | grep :8080 || echo "Port 8080 appears to be free"
  echo "🔍 Checking for existing nginx processes..."
  ps aux | grep nginx || echo "No nginx processes found"
  [ -n "$SIDEKIQ_PID" ] && kill $SIDEKIQ_PID 2>/dev/null
  [ -n "$STREAMING_PID" ] && kill $STREAMING_PID 2>/dev/null
  [ -n "$WEB_PID" ] && kill $WEB_PID 2>/dev/null
  exit 1
fi

if [ "$LOCAL_TEST_MODE" = "true" ]; then
  echo "📍 App should be available at http://localhost:80"
  echo "🔍 Monitoring processes..."

  # Wait for the web process (this keeps the container alive)
  wait $WEB_PID

  # If we get here, nginx died
  echo "❌ Nginx died, shutting down..."
  [ -n "$SIDEKIQ_PID" ] && kill $SIDEKIQ_PID 2>/dev/null
  [ -n "$STREAMING_PID" ] && kill $STREAMING_PID 2>/dev/null
  [ -n "$WEB_PID" ] && kill $WEB_PID 2>/dev/null
  exit 1
else
  echo "📍 App should be available at https://entangled.club"
  echo "🌊 Streaming should be available at wss://entangled.club/api/v1/streaming/"
  echo "🔍 Monitoring processes..."

  # Wait for any of the main processes to exit (nginx already started above)
  wait -n $SIDEKIQ_PID $STREAMING_PID $WEB_PID

  # If we get here, one of the processes died
  echo "❌ A critical process died, shutting down..."
  [ -n "$SIDEKIQ_PID" ] && kill $SIDEKIQ_PID 2>/dev/null
  [ -n "$STREAMING_PID" ] && kill $STREAMING_PID 2>/dev/null
  [ -n "$WEB_PID" ] && kill $WEB_PID 2>/dev/null
  exit 1
fi
