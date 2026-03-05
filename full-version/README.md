# Berry React Admin — Production Docker + Nginx

Tài liệu này giải thích toàn bộ quyết định kỹ thuật khi đóng gói và triển khai ứng dụng React (TypeScript) dưới dạng container production-grade.

---
## Quick Start

```bash
# 1. Cấu hình env (copy rồi điền giá trị)
cp .env.example .env     # hoặc sửa trực tiếp .env

# 2. Build & Run
docker compose up -d --build

# 3. Verify
curl http://localhost:3000/health    # → "OK"
curl -I http://localhost:3000/       # → 200, no-cache headers

# 4. Logs
docker compose logs -f berry-app

# Debug — xem nginx config đã được render từ template
docker compose exec berry-app cat /etc/nginx/conf.d/app.conf
```

**.env có 2 loại vars:**

| Loại | Prefix | Thời điểm đọc | Khi nào cần `--build` |
|---|---|---|---|
| Build-time | `REACT_APP_*` | `npm run build` → bake vào JS bundle | Có — đổi là phải build lại |
| Runtime | `NGINX_*` | Container start → `envsubst` → nginx config | Không — chỉ cần restart |


## 1. Multi-stage Build & Layer Cache

**Vấn đề:** Mỗi lần sửa code mà phải cài lại `node_modules` → tốn 2–3 phút.

**Giải pháp:** Tách thành 3 stage:

```
Stage 1 — deps     : COPY package.json → npm ci
Stage 2 — builder  : COPY node_modules (từ deps) → COPY source → npm run build
Stage 3 — runtime  : COPY /app/build → nginx (không có Node, npm, source code)
```

**Tại sao hiệu quả:**
- Docker cache layer theo thứ tự. `package.json` ít thay đổi → layer `npm ci` được cache.
- Chỉ khi `package.json` đổi mới trigger reinstall.
- Sửa source code chỉ invalidate từ `COPY . .` trở xuống.

**Kích thước image:** Runtime chỉ chứa nginx + static files → < 40MB.

---

## 2. Non-root Container

**Vấn đề:** Chạy nginx với root → nếu bị exploit, attacker có full quyền trong container.

**Giải pháp:**
- Dockerfile: `USER nginx` (uid=101, nginx:alpine có sẵn user này)
- nginx.conf: không có `user` directive (nginx tự chạy theo process user)
- Tất cả thư mục cần write được `chown nginx:nginx` trong Dockerfile
- tmpfs trong docker-compose thêm `uid=101,gid=101` để mount đúng owner ngay từ đầu

**Lý do phải thêm uid vào tmpfs:** Docker mount tmpfs sau khi image build xong → ghi đè `chown` đã làm trong Dockerfile. Phải chỉ định uid/gid ở mount options.

```yaml
tmpfs:
  - /tmp/nginx:size=10M,uid=101,gid=101
  - /etc/nginx/conf.d:size=1M,uid=101,gid=101   # bắt buộc nếu dùng dynamic config
```

`/etc/nginx/conf.d` cần tmpfs riêng vì `read_only: true` block write — entrypoint cần ghi `app.conf` vào đây lúc startup. Không có tmpfs này → "Read-only file system" error.

---

## 3. Healthcheck

**Endpoint:** `GET /health` → trả về `200 OK` (text/plain).

**Tại sao không dùng `index.html`:**
- `index.html` là business logic (SPA entry point), có thể bị cache, redirect, hoặc trả 304.
- Health endpoint phải luôn trả 200 nhanh, không phụ thuộc app state.
- Load balancer/orchestrator (Docker, K8s) cần signal rõ ràng: alive hay dead.

**Cấu hình:**
```nginx
location = /health {
    access_log off;           # không pollute logs
    add_header Cache-Control "no-cache, no-store";
    return 200 "OK\n";
}
```

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8080/health || exit 1
```

**Tại sao dùng `127.0.0.1` thay vì `localhost`:**

BusyBox wget (Alpine) resolve `localhost` → `::1` (IPv6 loopback), nhưng nginx `listen 8080;` chỉ bind `0.0.0.0:8080` (IPv4) → "Connection refused". `127.0.0.1` bypass DNS resolution, connect thẳng IPv4.

---

## 4. Cache Strategy

### 4A. Hashed Static Assets (`/static/`)

Ví dụ: `/static/js/main.3f1a9c.js`

```nginx
location ^~ /static/ {
    expires 1y;
    add_header Cache-Control "public, max-age=31536000, immutable";
    etag off;
}
```

**Tại sao cache 1 năm + immutable:**
- CRA tạo hash từ nội dung file. Hash thay đổi → tên file thay đổi → URL mới hoàn toàn.
- URL cũ không bao giờ có nội dung khác → browser không cần revalidate.
- `immutable` nói thẳng với browser: "đừng bao giờ hỏi lại file này".
- Tắt ETag vì tên file đã đóng vai trò versioning.

### 4B. Non-hashed Assets (favicon, manifest, logo)

```nginx
location ~* ^/(favicon\.(ico|svg)|manifest\.json|logo.*)$ {
    expires 5m;
    add_header Cache-Control "public, max-age=300, must-revalidate";
    etag on;
}
```

Cache 5 phút + revalidation. Không có hash trong tên → phải cho phép browser kiểm tra lại.

### 4C. index.html — Không cache

```nginx
location = /index.html {
    expires -1;
    add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    etag on;
}
```

**Tại sao không cache index.html:** Xem phần Debug Scenario bên dưới.

---

## 5. Conditional Request (ETag / 304)

`etag on` trong nginx.conf (mặc định đã bật, khai báo rõ để tránh vô tình tắt).

**Cơ chế hoạt động:**
1. Browser GET `/index.html` → nginx trả về `ETag: "abc123"` kèm nội dung.
2. Lần sau, browser gửi `If-None-Match: "abc123"`.
3. Nếu file không đổi → nginx trả `304 Not Modified` (không có body) → tiết kiệm bandwidth.

Không disable ETag để "đơn giản hóa" — đó là bỏ đi một cơ chế tiết kiệm bandwidth quan trọng.

---

## 6. Gzip Compression

```nginx
gzip on;
gzip_min_length 1024;   # Không nén file < 1KB (overhead > lợi ích)
gzip_comp_level 6;      # Cân bằng CPU vs tỉ lệ nén
gzip_types text/plain text/css application/javascript application/json image/svg+xml ...;
```

**Không nén:**
- `image/png`, `image/jpeg`, `image/webp` — đã nén sẵn trong format
- `font/woff`, `font/woff2` — đã nén sẵn
- `application/zip`, `application/gzip` — đã nén

**Lý do:** Nén file đã nén → tốn CPU, tăng TTFB, kết quả còn to hơn hoặc bằng.

`gzip_vary on` → thêm `Vary: Accept-Encoding` để CDN/proxy cache đúng cả bản gzip lẫn plain.

---

## 7. Nginx Config Structure

```
nginx/
├── nginx.conf               # Global: worker, gzip, open_file_cache, logging
├── docker-entrypoint.sh     # Xử lý envsubst trước khi nginx start
└── templates/
    └── app.conf.template    # Server block với ${VARIABLE} placeholders (sinh conf.d/app.conf lúc runtime)
```

**Không sửa `/etc/nginx/conf.d/default.conf`** — xóa file đó đi, dùng file riêng. Tránh conflict và dễ quản lý.

**Các tuning khác:**
- `server_tokens off` — ẩn version nginx khỏi response header và error page
- `autoindex off` — không liệt kê thư mục
- Chỉ cho phép `GET`, `HEAD`, `OPTIONS` — SPA không cần POST/DELETE
- Rate limit: `10r/s` cho app routes, `100r/s` cho static assets
- `limit_req_status 429` — trả 429 Too Many Requests (default là 503 — sai semantic)
- `open_file_cache max=1000` — cache file descriptor, giảm syscall khi serve static

---

## 8. SPA Routing Edge Cases

```nginx
location / {
    try_files $uri $uri/ /index.html;
}

location ~* \.(js|css|png|...)$ {
    try_files $uri =404;   # File có extension mà không tồn tại → 404 thật
}
```

| Request | Kết quả | Giải thích |
|---|---|---|
| `/admin` | `index.html` → React Router xử lý | không phải file → fallback |
| `/admin/` | `index.html` → React Router xử lý | không phải dir → fallback |
| `/admin/settings` | `index.html` → React Router xử lý | không phải file → fallback |
| `/random.txt` | `404` | có extension → block extension → `try_files =404` |
| `/static/main.abc.js` | file thật | block `/static/` bắt trước bởi `^~` |

**`^~` prefix** trên `/static/` đảm bảo block này được chọn trước bất kỳ regex nào khác.

---

## 9. Debug Scenario

### Vì sao static asset nên immutable?

Vì tên file chứa content hash (`main.3f1a9c.js`). Nếu nội dung thay đổi → hash thay đổi → URL hoàn toàn khác. URL cũ sẽ không bao giờ trỏ đến nội dung khác → cache mãi mãi là an toàn tuyệt đối. `immutable` giúp browser bỏ qua conditional request, giảm round-trip.

### Tại sao không cache index.html?

`index.html` là "bản đồ" của app — nó chứa link đến các file JS/CSS đã hashed. Khi deploy version mới:
- Các file JS/CSS có URL mới (hash mới) → đã được cache đúng.
- `index.html` phải trỏ đến URL mới → nếu bị cache, user vẫn nhận `index.html` cũ → load JS/CSS cũ → không thấy version mới.

### Điều gì xảy ra nếu cache index.html 1 năm?

User sẽ không thấy bất kỳ update nào trong 1 năm (hoặc đến khi clear cache). Mọi deploy mới đều vô hiệu với user đó. Đây là lỗi nghiêm trọng nhất trong SPA deployment.

### Khi nào cần `no-store` thay vì `no-cache`?

- `no-cache`: Browser vẫn lưu vào cache, nhưng phải revalidate trước khi dùng (gửi `If-None-Match` → có thể nhận 304).
- `no-store`: Không lưu gì cả, luôn fetch full response.

Dùng `no-store` khi response chứa dữ liệu nhạy cảm (token, thông tin cá nhân, API response private). Với `index.html` của SPA public, `no-cache` là đủ — nhưng thêm `no-store` để chắc chắn hơn với proxy/CDN trung gian.

### Debug khi user không thấy version mới sau deploy

1. **Kiểm tra `index.html`:** `curl -I https://domain/` → xem `Cache-Control`, `ETag`. Nếu có `max-age` > 0 → đây là nguyên nhân.
2. **Kiểm tra CDN:** CDN đang cache `index.html`? → Purge cache CDN.
3. **Kiểm tra browser:** DevTools → Network → disable cache → reload. Nếu thấy version mới → lỗi browser cache.
4. **Kiểm tra Service Worker:** App có PWA? SW có thể cache `index.html` → cần update SW hoặc unregister.
5. **Kiểm tra nginx config:** `server_tokens off` che version → xem response header `Server`.

---

## 10. Image Security

| Biện pháp | Cách thực hiện |
|---|---|
| Không có Node/npm trong runtime | Multi-stage: stage 3 là `nginx:alpine` |
| Không có source code | Chỉ `COPY --from=builder /app/build` |
| Không lộ `.env` | `.dockerignore` exclude `.env*`; dùng build args |
| Không lộ source map | `GENERATE_SOURCEMAP=false` + `find /app/build -name '*.map' -delete` + nginx block `.map$` → 404 |
| Không lộ nginx version | `server_tokens off` |
| Không có `apk` package manager | `apk del apk-tools` trong runtime stage |
| Non-root | `USER nginx` |
| No new privileges | `security_opt: no-new-privileges:true` |
| Read-only filesystem | `read_only: true` + tmpfs cho các thư mục cần write |

**Truyền env vars an toàn — 2 luồng riêng biệt:**
```
.env (host)
 ├─ REACT_APP_* → docker-compose build.args → Dockerfile ARG/ENV → npm run build → bake vào JS bundle
 └─ NGINX_*     → docker-compose environment → container runtime → entrypoint.sh → nginx config
```
File `.env` không bao giờ vào image. `REACT_APP_*` chỉ truyền giá trị qua build args. `NGINX_*` chỉ tồn tại trong process environment của container.

---

## 11. Stress Simulation — 10k Concurrent Users

### Nginx bottleneck ở đâu?

| Thành phần | Bottleneck |
|---|---|
| `worker_processes auto` | = số CPU cores. 1 CPU → 1 worker → giới hạn throughput |
| `worker_connections 1024` | Tổng connections = `worker_processes × 1024`. 1 worker = 1024 connections max |
| `open_file_cache max=1000` | Cache 1000 file descriptor. Nếu có nhiều file hơn → cache miss → tăng syscall |
| Memory | Mỗi connection ~20KB. 10k connections = ~200MB RAM |
| `client_max_body_size 1m` | Không phải bottleneck cho SPA (không có upload) |

Với `deploy.resources.limits.memory: 128M` hiện tại → không đủ cho 10k concurrent. Cần nâng lên ít nhất 512M.

### Docker limit nên cấu hình gì?

```yaml
deploy:
  resources:
    limits:
      memory: 512M      # Nâng từ 128M
      cpus: "2.0"       # Nâng từ 0.5
    reservations:
      memory: 128M
      cpus: "0.5"
```

### Hướng scale

**Scale vertical (1 server mạnh hơn):**
- Tăng `worker_connections` lên 4096
- Tăng `worker_rlimit_nofile` lên 65536
- Tăng resource limit của container

**Scale horizontal (nhiều container):**
```
User → CDN (CloudFlare/CloudFront)
           ↓ cache miss
       Load Balancer (nginx upstream / AWS ALB)
           ↓ round-robin
    [berry-container-1] [berry-container-2] [berry-container-3]
```

Vì app là **static files** (không có state, không có session):
- Mỗi container hoàn toàn độc lập → scale out không cần sticky session
- CDN cache `index.html` với `s-maxage=0` (không cache) nhưng cache `/static/*` vô thời hạn → giảm tải xuống origin gần như hoàn toàn
- Thực tế với SPA static: 10k concurrent users → CDN xử lý hầu hết → origin chỉ nhận ~1–5% traffic thật

**Không cần Kubernetes** cho scale đơn giản: Docker Swarm hoặc 3–5 instance sau Load Balancer là đủ cho hầu hết traffic thực tế.

---

## 12. Dynamic Nginx Config via Environment Variables

**Vấn đề:** Nginx config bị hardcode trong image — muốn đổi `server_name`, rate limit, hay body size phải build lại image.

**Giải pháp:** Config được sinh ra lúc container khởi động từ template + env vars, dùng `envsubst`.

### Cách implement

**3 thành phần:**

```
nginx/templates/app.conf.template  ← template chứa ${VARIABLE} placeholders
nginx/docker-entrypoint.sh         ← chạy envsubst → ghi /etc/nginx/conf.d/app.conf
Dockerfile                         ← chown conf.d cho nginx user, override ENTRYPOINT
```

**Flow khi container start:**

```
docker run -e NGINX_SERVER_NAME=berry.example.com ...
     │
     ▼
/docker-entrypoint.sh (chạy với USER nginx)
     │
     ├─ set defaults: NGINX_SERVER_NAME="${NGINX_SERVER_NAME:-_}"
     │
     ├─ envsubst '${NGINX_SERVER_NAME} ${NGINX_RATE_LIMIT_APP} ...'
     │       < /etc/nginx/templates/app.conf.template
     │       > /etc/nginx/conf.d/app.conf       ← file được sinh lúc runtime
     │
     ├─ nginx -t   ← validate trước khi start
     │
     └─ exec "$@"  → nginx -g 'daemon off;'
```

**Tại sao dùng explicit variable list trong envsubst:**

```sh
# SAI — envsubst thay hết $... kể cả nginx's own variables
envsubst < template > output

# ĐÚNG — chỉ thay ${NGINX_*} vars, giữ nguyên $uri, $request_method, $binary_remote_addr...
envsubst '${NGINX_SERVER_NAME} ${NGINX_RATE_LIMIT_APP}' < template > output
```

Nginx dùng `$variable` syntax cho internal variables (`$uri`, `$remote_addr`...). Nếu không filter, `envsubst` sẽ replace chúng thành chuỗi rỗng → config bị vỡ.

**Vấn đề non-root:** `USER nginx` trong Dockerfile → entrypoint chạy với quyền nginx, không write được vào `/etc/nginx/conf.d/` (root-owned). Fix trong Dockerfile:

```dockerfile
RUN chown nginx:nginx /etc/nginx/conf.d;  # nginx user có quyền ghi
```

### Env vars được hỗ trợ

| Env var | Default | Ý nghĩa |
|---|---|---|
| `NGINX_SERVER_NAME` | `_` | Domain / hostname |
| `NGINX_RATE_LIMIT_APP` | `10r/s` | Rate limit SPA routes |
| `NGINX_RATE_LIMIT_STATIC` | `100r/s` | Rate limit `/static/` |
| `NGINX_RATE_BURST_APP` | `20` | Burst size app routes |
| `NGINX_RATE_BURST_STATIC` | `200` | Burst size static |
| `NGINX_CLIENT_MAX_BODY_SIZE` | `1m` | Max request body |

### Cách dùng

**Với docker-compose (recommended)** — sửa `.env`, restart container, không cần build lại:

```bash
# .env
NGINX_SERVER_NAME=admin.company.com
NGINX_RATE_LIMIT_APP=20r/s
NGINX_RATE_BURST_APP=50

# Apply thay đổi (không cần --build)
docker compose up -d

# Confirm config đã được render đúng
docker compose exec berry-app cat /etc/nginx/conf.d/app.conf
```

**Với docker run** (CI/CD pipeline, K8s):

```bash
docker run \
  -e NGINX_SERVER_NAME=admin.company.com \
  -e NGINX_RATE_LIMIT_APP=20r/s \
  -p 3000:8080 full-version-berry-app:latest
```

**Kết quả:** Cùng 1 image deploy được dev/staging/production với config khác nhau — không cần build lại image.

### Thêm variable mới

1. Thêm `${NGINX_NEW_VAR}` vào `nginx/templates/app.conf.template`
2. Thêm default + thêm vào list envsubst trong `nginx/docker-entrypoint.sh`

---

## Cấu trúc Files

```
full-version/
├── Dockerfile              # 3-stage build
├── docker-compose.yml      # Container config + build args
├── .dockerignore           # Exclude node_modules, .env, build tools
├── nginx/
│   ├── nginx.conf              # Global nginx config (static)
│   ├── docker-entrypoint.sh    # Xử lý envsubst, validate, start nginx
│   └── templates/
│       └── app.conf.template   # Server block template (sinh conf.d/app.conf lúc runtime)
└── .env                    # Env vars (không vào image, đọc bởi docker-compose)
```
