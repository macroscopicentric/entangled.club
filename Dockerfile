FROM ghcr.io/glitch-soc/mastodon:latest

# Switch to root to install packages
USER root

# Install only the dependencies we actually need (curl and openssl already available)
RUN apt-get update && apt-get install -y \
    postgresql-client \
    nodejs \
    npm \
    nginx \
    redis-server \
    sqlite3 \
    libsqlite3-dev \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Create nginx directories and set permissions for mastodon user
RUN mkdir -p /var/lib/nginx/body /var/log/nginx /run \
    && chown -R mastodon:mastodon /var/lib/nginx /var/log/nginx /etc/nginx /run \
    && chmod -R 755 /var/lib/nginx /var/log/nginx /run

# Install streaming server dependencies using npm with legacy peer deps to avoid conflicts
WORKDIR /opt/mastodon/streaming
RUN npm install --omit=dev --legacy-peer-deps

# Return to main directory
WORKDIR /opt/mastodon

# Set production environment for both local and Fly deployments
ENV RAILS_ENV=production
ENV NODE_ENV=production
ENV RAILS_SERVE_STATIC_FILES=true
ENV RAILS_LOG_TO_STDOUT=true

# Copy nginx configuration and startup script
COPY nginx.conf /etc/nginx/nginx.conf
COPY start.sh /usr/local/bin/start.sh

# Copy .env.local if it exists (for local development)
COPY .env.local* /opt/mastodon/

RUN chmod +x /usr/local/bin/start.sh

# Switch back to mastodon user
USER mastodon

# Expose port 8080 for nginx (which will proxy to Rails and streaming)
EXPOSE 8080

# Start the application
CMD ["/usr/local/bin/start.sh"]