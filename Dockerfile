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

# Copy and setup startup script
COPY start.sh /usr/local/bin/start.sh

RUN chmod +x /usr/local/bin/start.sh

# Switch back to mastodon user
USER mastodon

# Expose the port
EXPOSE 3000

# Start the application
CMD ["/usr/local/bin/start.sh"]