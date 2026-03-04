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
    # Remove source maps if any were generated despite env var
    find /app/build -name '*.map' -delete

# Stage 3: runtime — Production nginx (NO Node, npm, source code, build tools)
FROM nginx:1.27-alpine AS runtime

LABEL maintainer="VNCloudOps" \
      description="Berry React Admin Dashboard - Production Container" \
      version="3.6.0"

# Remove default nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom nginx configuration
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/conf.d/ /etc/nginx/conf.d/

# Copy built static files only (no source code)
COPY --from=builder /app/build /usr/share/nginx/html

# Security hardening & non-root setup
# nginx:alpine ships with nginx user (uid 101)
RUN set -eux; \
    # Set ownership for non-root operation
    chown -R nginx:nginx /usr/share/nginx/html; \
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
    CMD wget -q --spider http://localhost:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
