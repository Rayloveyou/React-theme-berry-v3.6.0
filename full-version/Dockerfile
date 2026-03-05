# REACT_APP_* vars are intentionally baked into the JS bundle by CRA (public by design)
# Suppressing SecretsUsedInArgOrEnv false positives for Firebase/AWS/Auth0 build args
# check=skip=SecretsUsedInArgOrEnv

# Stage 1: deps — Install dependencies
FROM node:18-alpine AS deps

WORKDIR /app

COPY package.json package-lock.json ./

# Install all dependencies (devDependencies needed for build tools)
RUN npm ci --frozen-lockfile && \
    # Clean npm cache to reduce layer size
    npm cache clean --force

# Stage 2: builder — Build production React bundle
FROM node:18-alpine AS builder

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules

COPY . .

# Build-time env vars (REACT_APP_* are baked into the JS bundle by CRA)
ARG REACT_APP_VERSION
ARG REACT_APP_API_URL
ARG REACT_APP_FIREBASE_API_KEY
ARG REACT_APP_FIREBASE_AUTH_DOMAIN
ARG REACT_APP_FIREBASE_PROJECT_ID
ARG REACT_APP_FIREBASE_STORAGE_BUCKET
ARG REACT_APP_FIREBASE_MESSAGING_SENDER_ID
ARG REACT_APP_FIREBASE_APP_ID
ARG REACT_APP_FIREBASE_MEASUREMENT_ID
ARG REACT_APP_AWS_POOL_ID
ARG REACT_APP_AWS_APP_CLIENT_ID
ARG REACT_APP_AUTH0_CLIENT_ID
ARG REACT_APP_AUTH0_DOMAIN

ENV REACT_APP_VERSION=$REACT_APP_VERSION \
    REACT_APP_API_URL=$REACT_APP_API_URL \
    REACT_APP_FIREBASE_API_KEY=$REACT_APP_FIREBASE_API_KEY \
    REACT_APP_FIREBASE_AUTH_DOMAIN=$REACT_APP_FIREBASE_AUTH_DOMAIN \
    REACT_APP_FIREBASE_PROJECT_ID=$REACT_APP_FIREBASE_PROJECT_ID \
    REACT_APP_FIREBASE_STORAGE_BUCKET=$REACT_APP_FIREBASE_STORAGE_BUCKET \
    REACT_APP_FIREBASE_MESSAGING_SENDER_ID=$REACT_APP_FIREBASE_MESSAGING_SENDER_ID \
    REACT_APP_FIREBASE_APP_ID=$REACT_APP_FIREBASE_APP_ID \
    REACT_APP_FIREBASE_MEASUREMENT_ID=$REACT_APP_FIREBASE_MEASUREMENT_ID \
    REACT_APP_AWS_POOL_ID=$REACT_APP_AWS_POOL_ID \
    REACT_APP_AWS_APP_CLIENT_ID=$REACT_APP_AWS_APP_CLIENT_ID \
    REACT_APP_AUTH0_CLIENT_ID=$REACT_APP_AUTH0_CLIENT_ID \
    REACT_APP_AUTH0_DOMAIN=$REACT_APP_AUTH0_DOMAIN

# Enforce no source maps in production build
ENV GENERATE_SOURCEMAP=false
ENV NODE_ENV=production

RUN npm run build && \
    # Remove source maps
    find /app/build -name '*.map' -delete && \
    # Pre-compress text assets at max gzip level (JS compresses ~75%, CSS ~85%, SVG ~80%)
    find /app/build/static -type f \( -name "*.js" -o -name "*.css" -o -name "*.svg" \) \
        -exec gzip -9 -k {} \; && \
    # Delete uncompressed originals — nginx serves .gz via gzip_static always
    find /app/build/static -type f \( -name "*.js" -o -name "*.css" -o -name "*.svg" \) \
        ! -name "*.gz" -delete

# Stage 3: runtime — Production nginx (NO Node, npm, source code, build tools)
FROM nginx:1.27-alpine-slim AS runtime

LABEL maintainer="VNCloudOps" \
      description="Berry React Admin Dashboard - Production Container" \
      version="3.6.0"

# Remove default nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Copy static nginx config and app config template
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/templates/ /etc/nginx/templates/

# Copy custom entrypoint (processes app.conf.template → conf.d/app.conf at startup)
COPY nginx/docker-entrypoint.sh /docker-entrypoint.sh

# Copy built static files with correct ownership in a single layer (avoids chown duplicate layer)
COPY --chown=nginx:nginx --from=builder /app/build /usr/share/nginx/html

# Security hardening & non-root setup
# nginx:alpine ships with nginx user (uid 101)
RUN set -eux; \
    sed -i 's/\r$//' /docker-entrypoint.sh && chmod +x /docker-entrypoint.sh; \
    # Allow nginx user to write rendered template into conf.d at container startup
    chown nginx:nginx /etc/nginx/conf.d; \
    chown -R nginx:nginx /var/cache/nginx; \
    chown -R nginx:nginx /var/log/nginx; \
    touch /var/run/nginx.pid; \
    chown nginx:nginx /var/run/nginx.pid; \
    # Create tmp dirs for nginx (needed when running as non-root)
    mkdir -p /tmp/nginx/{client_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp}; \
    chown -R nginx:nginx /tmp/nginx; \
    # Remove .env files if accidentally copied
    find /usr/share/nginx/html -name '.env*' -delete 2>/dev/null || true; \
    # Remove asset-manifest.json (exposes internal build structure)
    rm -f /usr/share/nginx/html/asset-manifest.json; \
    # Remove package manager from runtime image (security requirement)
    apk --no-cache del apk-tools 2>/dev/null || true; \
    rm -rf /var/cache/apk/* /tmp/* /root/.cache

# Switch to non-root user
USER nginx

# Non-privileged port
EXPOSE 8080

# Health check — dedicated /health endpoint, NOT index.html
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
