# Docker Deployment — Berry React Admin Dashboard

Production-grade containerization with Docker + Nginx.

**Git:** github.com/VNCloudOps/react-theme-berry-v3.6.0

---

## Quick Start

```bash
# Build & Run
docker compose up -d --build

# Verify
curl http://localhost:3000/health    # → "OK"
curl -I http://localhost:3000/       # → 200, no-cache headers

# Logs
docker compose logs -f berry-app
```

---

## 1. Multi-stage Build với Tối ưu Layer Cache

**File:** `Dockerfile`

### Architecture

```
Stage 1: deps     → Install node_modules (cached khi package.json ko đổi)
Stage 2: builder  → Build React app (chỉ rebuild khi source thay đổi)
Stage 3: runtime  → Nginx Alpine (KHÔNG có Node, npm, source code, build tools)
```

### Layer Cache Strategy

| Layer | Rebuild khi... | Cache khi... |
|-------|----------------|--------------|
| `COPY package.json package-lock.json` | dependency thay đổi | source thay đổi |
| `npm ci` | package.json đổi | source thay đổi |
| `COPY . .` | source code đổi | — |
| `npm run build` | source đổi | — |

### Runtime Image Content

Runtime image **CHỈ** chứa:
- Nginx binary + config
- Built static files (HTML/CSS/JS)
- Alpine base libs

**KHÔNG** chứa:
- ❌ Node.js
- ❌ npm / package manager
- ❌ Source code (.tsx, .ts)
- ❌ node_modules
- ❌ Build toolchain (webpack, babel)
- ❌ Source maps (.map files)
- ❌ asset-manifest.json

### Image Size

Target: **< 40MB** (không tính base image layer cached local)

```bash
# Verify image size
docker images berry-react-app --format "table {{.Repository}}\t{{.Size}}"

# Check layer sizes
docker history berry-react-app
```

Ước tính: ~5-8MB custom layers (Nginx config + React build output).

---

## 2. Non-root Container

**Tại sao:** Giảm attack surface. Container bị compromise → attacker KHÔNG có root.

### Implementation

```dockerfile
# Dockerfile — Stage 3
USER nginx          # uid=101, gid=101 (nginx:alpine built-in)
EXPOSE 8080         # Non-privileged port (>1024, ko cần root)
```

### Permissions Setup

```dockerfile
RUN chown -R nginx:nginx /usr/share/nginx/html \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/log/nginx \
    && touch /var/run/nginx.pid \
    && chown nginx:nginx /var/run/nginx.pid
```

### Docker Compose Hardening

```yaml
security_opt:
  - no-new-privileges:true    # Prevent privilege escalation
read_only: true                # Read-only filesystem
tmpfs:                         # Writable tmpfs only where needed
  - /tmp/nginx:size=10M
  - /var/cache/nginx:size=50M
  - /var/run:size=1M
```

### Verify

```bash
docker exec berry-react-app id
# → uid=101(nginx) gid=101(nginx)

docker exec berry-react-app whoami
# → nginx
```

---

## 3. Healthcheck

**Yêu cầu:** Endpoint riêng biệt, KHÔNG dùng index.html.

### Nginx Config (`nginx/conf.d/app.conf`)

```nginx
location = /health {
    access_log off;                              # Không spam log
    add_header Content-Type text/plain;
    add_header Cache-Control "no-cache, no-store";
    return 200 "OK\n";
}
```

### Docker HEALTHCHECK

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider http://localhost:8080/health || exit 1
```

| Parameter | Value | Lý do |
|-----------|-------|-------|
| `interval` | 30s | Cân bằng giữa phát hiện nhanh và tải hệ thống |
| `timeout` | 3s | Nginx phải respond < 3s hoặc coi như dead |
| `start-period` | 5s | Cho nginx thời gian khởi động |
| `retries` | 3 | 3 lần fail liên tục → unhealthy |

### Verify

```bash
# Check health status
docker inspect --format='{{.State.Health.Status}}' berry-react-app
# → healthy

# Manual test
curl -v http://localhost:3000/health
# → 200 OK
```

---

## 4. Cache Strategy theo Loại File

**File:** `nginx/conf.d/app.conf`

### 4A. Hashed Static Assets (`/static/*`)

CRA output: `/static/js/main.3f1a9c.js`, `/static/css/main.a2b4c6.css`

```nginx
location ^~ /static/ {
    expires 1y;
    add_header Cache-Control "public, max-age=31536000, immutable";
    etag off;              # Không cần — filename = content hash
    if_modified_since off; # Không cần revalidation
}
```

| Header | Value | Lý do |
|--------|-------|-------|
| `max-age` | 31536000 (1 năm) | File name chứa hash → safe cache vĩnh viễn |
| `immutable` | yes | Browser KHÔNG gửi conditional request |
| `ETag` | off | Redundant — hash trong filename |

### 4B. Non-hashed Assets (favicon, manifest, logos)

```nginx
location ~* ^/(favicon\.(ico|svg)|manifest\.json|logo.*\.(png|svg|ico))$ {
    expires 5m;
    add_header Cache-Control "public, max-age=300, must-revalidate";
    etag on;    # Enable conditional requests
}
```

### 4C. index.html — KHÔNG cache

```nginx
location = /index.html {
    expires -1;
    add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    add_header Pragma "no-cache" always;
    etag on;    # Hỗ trợ conditional request (304)
}
```

### Verify

```bash
# Hashed asset — should have 1y cache + immutable
curl -I http://localhost:3000/static/js/main.*.js

# index.html — should have no-cache
curl -I http://localhost:3000/

# Non-hashed — should have 5m cache
curl -I http://localhost:3000/favicon.svg
```

---

## 5. Conditional Request Support (ETag / 304)

### How It Works

```
Browser 1st request:
  GET /index.html → 200 OK
  Response: ETag: "65a1b2c3-1234"

Browser 2nd request:
  GET /index.html
  If-None-Match: "65a1b2c3-1234"
  → 304 Not Modified (no body transferred, saves bandwidth)
```

### Nginx Config

```nginx
# Global (nginx.conf)
etag on;   # Enabled by default, explicit for clarity

# Per-location override
location = /index.html { etag on; }       # ✓ Always revalidate
location ^~ /static/    { etag off; }      # ✗ Not needed (immutable)
```

### Verify

```bash
# Step 1: Get ETag
ETAG=$(curl -sI http://localhost:3000/ | grep -i etag | tr -d '\r')
echo "$ETAG"
# → ETag: "65a1b2c3-1234"

# Step 2: Conditional request
curl -I -H "If-None-Match: ${ETAG#*: }" http://localhost:3000/
# → HTTP/1.1 304 Not Modified
```

---

## 6. Gzip / Compression

**File:** `nginx/nginx.conf`

### Config

```nginx
gzip on;
gzip_vary on;
gzip_min_length 1024;    # Skip files < 1KB
gzip_comp_level 6;       # Good compression/CPU balance
```

### MIME Types — Chỉ Nén Loại Phù Hợp

| Nén ✓ | KHÔNG nén ✗ (đã compressed) |
|--------|---------------------------|
| text/plain | image/png |
| text/css | image/jpeg |
| text/javascript | image/gif |
| application/json | image/webp |
| application/javascript | font/woff |
| image/svg+xml | font/woff2 |
| application/xml | application/zip |

### Verify

```bash
# Should have Content-Encoding: gzip
curl -sI -H "Accept-Encoding: gzip" http://localhost:3000/ | grep -i content-encoding
# → Content-Encoding: gzip

# Compressed size vs original
curl -so /dev/null -w "Size: %{size_download}\n" http://localhost:3000/
curl -so /dev/null -w "Gzip: %{size_download}\n" -H "Accept-Encoding: gzip" http://localhost:3000/
```

---

## 7. Nginx Deep Config

### File Structure

```
nginx/
├── nginx.conf           # Main config: workers, events, http globals
└── conf.d/
    └── app.conf         # Server block: routing, cache, security
```

**KHÔNG** sửa `/etc/nginx/conf.d/default.conf` — file này bị xóa trong Dockerfile.

### Worker Tuning

```nginx
worker_processes auto;          # Match CPU cores
worker_rlimit_nofile 8192;     # File descriptor limit
worker_connections 1024;        # Max connections per worker
multi_accept on;                # Accept all pending connections
```

### Open File Cache

```nginx
open_file_cache          max=1000 inactive=20s;
open_file_cache_valid    30s;     # Check file changes every 30s
open_file_cache_min_uses 2;      # Cache after 2 accesses
open_file_cache_errors   on;     # Cache 404s too
```

### Rate Limiting

```nginx
# App routes: 10 req/s per IP
limit_req_zone $binary_remote_addr zone=app_limit:10m rate=10r/s;

# Static assets: 100 req/s per IP (browsers load many files in parallel)
limit_req_zone $binary_remote_addr zone=static_limit:10m rate=100r/s;
```

### Security Checklist

| Feature | Status | Config |
|---------|--------|--------|
| Server version hidden | ✓ | `server_tokens off` |
| Directory listing disabled | ✓ | `autoindex off` |
| Method restriction | ✓ | Only GET/HEAD/OPTIONS |
| Hidden files blocked | ✓ | `location ~ /\. { deny all; }` |
| Security headers | ✓ | X-Frame-Options, X-Content-Type-Options, etc. |
| Rate limiting | ✓ | Per-zone limits with burst |

---

## 8. SPA Routing Edge Cases

### Routing Logic

```nginx
# 1. Files with extensions → serve directly or 404
location ~* \.(js|css|png|...|txt|json)$ {
    try_files $uri =404;
}

# 2. Everything else → SPA fallback
location / {
    try_files $uri $uri/ /index.html;
}
```

### Test Cases

| Request | Expected | Actual Behavior |
|---------|----------|-----------------|
| `/admin` | → index.html (SPA route) | ✓ No file extension → `location /` → index.html |
| `/admin/` | → index.html (SPA route) | ✓ No file → `try_files $uri/` fails → index.html |
| `/admin/settings` | → index.html (SPA route) | ✓ No extension → SPA fallback |
| `/static/js/main.abc.js` | → serve JS file | ✓ `^~ /static/` catches it |
| `/random.txt` | → 404 | ✓ Has `.txt` extension → `try_files $uri =404` → 404 |
| `/nonexistent.css` | → 404 | ✓ Has `.css` extension → file not found → 404 |
| `/favicon.svg` | → serve file | ✓ Matched by extension block |
| `/.env` | → 404 (denied) | ✓ `location ~ /\.` blocks hidden files |
| `/main.js.map` | → 404 | ✓ `location ~* \.map$` returns 404 |

### Verify

```bash
# SPA routes → 200
curl -o /dev/null -s -w "%{http_code}" http://localhost:3000/admin
# → 200

curl -o /dev/null -s -w "%{http_code}" http://localhost:3000/admin/settings
# → 200

# Missing files → 404
curl -o /dev/null -s -w "%{http_code}" http://localhost:3000/random.txt
# → 404

# Hidden files → 404
curl -o /dev/null -s -w "%{http_code}" http://localhost:3000/.env
# → 404
```

---

## 9. Image Security

### Security Measures

| Threat | Mitigation | Implementation |
|--------|------------|----------------|
| Root escalation | Non-root user | `USER nginx` + `no-new-privileges` |
| Package manager abuse | Removed from runtime | `apk del apk-tools` |
| Source code leak | Not in runtime image | Multi-stage build, only `build/` copied |
| Source map exposure | Deleted + nginx block | `find -name '*.map' -delete` + `location ~* \.map$ { return 404; }` |
| .env file leak | Deleted from image + nginx block | `find -name '.env*' -delete` + `location ~ /\. { deny all; }` |
| Build info leak | asset-manifest.json removed | `rm -f asset-manifest.json` |
| Server fingerprint | Version hidden | `server_tokens off` |
| Filesystem tampering | Read-only container | `read_only: true` in compose |
| Directory traversal | Listing disabled | `autoindex off` |
| Unwanted methods | Method whitelist | Only GET/HEAD/OPTIONS allowed |

### Verify

```bash
# No Node.js in runtime
docker exec berry-react-app node --version 2>&1
# → OCI runtime exec failed (no node binary)

# No npm
docker exec berry-react-app npm --version 2>&1
# → OCI runtime exec failed

# No source maps
docker exec berry-react-app find /usr/share/nginx/html -name '*.map' | wc -l
# → 0

# No .env files
docker exec berry-react-app find /usr/share/nginx/html -name '.env*' | wc -l
# → 0

# Server version hidden
curl -sI http://localhost:3000/ | grep -i server
# → Server: nginx (no version number)

# Running as non-root
docker exec berry-react-app id
# → uid=101(nginx) gid=101(nginx)
```

---

## Production Operations

### Build

```bash
docker compose build                    # Build image
docker compose up -d                    # Start container
docker compose ps                       # Check status
docker compose logs -f berry-app        # Stream logs
```

### Scaling

```bash
# Scale horizontally (behind load balancer)
docker compose up -d --scale berry-app=3
```

### Monitoring

```bash
# Container health
docker inspect --format='{{.State.Health.Status}}' berry-react-app

# Resource usage
docker stats berry-react-app

# Access logs
docker compose logs berry-app | grep -v "/health"
```

---

## File Structure Summary

```
full-version/
├── Dockerfile              # Multi-stage build (3 stages)
├── .dockerignore           # Exclude unnecessary files from build context
├── docker-compose.yml      # Production compose with security hardening
├── nginx/
│   ├── nginx.conf          # Main: workers, gzip, etag, open_file_cache
│   └── conf.d/
│       └── app.conf        # Server: cache strategy, SPA routing, security
└── docs/
    └── docker-deployment.md  # This file
```
