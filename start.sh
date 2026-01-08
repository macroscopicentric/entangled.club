#!/bin/bash
set -e

# Debug: Show what DATABASE_URL we're using
echo "🔍 DATABASE_URL: $DATABASE_URL"

# Ensure we have required configuration
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

echo "🔗 Database: $DATABASE_URL"
echo "🔗 Redis: $REDIS_URL"

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

# Start both web server and Sidekiq
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

# Start Sidekiq in background
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

# Start web server in background
echo "🔄 Starting web server..."
bundle exec rails server -b 0.0.0.0 -p 3000 &
WEB_PID=$!

# Give web server a moment to start
sleep 3

# Check if web server started successfully
if kill -0 $WEB_PID 2>/dev/null; then
  echo "✅ Web server started successfully (PID: $WEB_PID)"
else
  echo "❌ Web server failed to start, exiting..."
  [ -n "$SIDEKIQ_PID" ] && kill $SIDEKIQ_PID 2>/dev/null
  exit 1
fi

# Monitor both processes - wait for web server to exit
echo "🔍 Monitoring processes..."
echo "📍 App should be available at https://entangled.club"

# Wait for the web server process (this keeps the container alive)
wait $WEB_PID

# If we get here, web server died
echo "❌ Web server died, shutting down..."
[ -n "$SIDEKIQ_PID" ] && kill $SIDEKIQ_PID 2>/dev/null
exit 1
