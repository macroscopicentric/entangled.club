FROM ghcr.io/glitch-soc/mastodon:latest

# Switch to root to install packages
USER root

# Install additional dependencies
RUN apt-get update && apt-get install -y \
    curl \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Set environment variables for production
ENV RAILS_ENV=production
ENV NODE_ENV=production
ENV RAILS_SERVE_STATIC_FILES=true
ENV RAILS_LOG_TO_STDOUT=true

# Create startup script (as root)
RUN cat > /usr/local/bin/start.sh << 'EOF'
#!/bin/bash
set -e

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
until bundle exec rails runner "ActiveRecord::Base.connection.execute('SELECT 1')" 2>/dev/null; do
  echo "Database not ready, waiting..."
  sleep 2
done
echo "✅ Database is ready"

# Run database setup
echo "🗄️ Setting up database..."
bundle exec rails db:create 2>/dev/null || echo "Database already exists"
bundle exec rails db:migrate
echo "✅ Database setup complete"

# Precompile assets if they don't exist
if [ ! -d "public/assets" ] || [ -z "$(ls -A public/assets 2>/dev/null)" ]; then
  echo "🎨 Precompiling assets..."
  bundle exec rails assets:precompile
  echo "✅ Assets precompiled"
fi

# Start the server
echo "🚀 Starting Mastodon web server..."

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
exec bundle exec rails server -b 0.0.0.0 -p 3000
EOF

RUN chmod +x /usr/local/bin/start.sh

# Switch back to mastodon user
USER mastodon

# Expose the port
EXPOSE 3000

# Start the application
CMD ["/usr/local/bin/start.sh"]