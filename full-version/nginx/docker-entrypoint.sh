#!/bin/sh
set -eu

# ---------------------------------------------------------------------------
# Custom nginx entrypoint — processes app.conf.template with runtime env vars
#
# IMPORTANT: envsubst is called with an EXPLICIT variable list to avoid
# replacing nginx's own $variable syntax ($uri, $request_method, etc.)
# ---------------------------------------------------------------------------

# Defaults for all supported env vars
export NGINX_SERVER_NAME="${NGINX_SERVER_NAME:-_}"
export NGINX_RATE_LIMIT_APP="${NGINX_RATE_LIMIT_APP:-10r/s}"
export NGINX_RATE_LIMIT_STATIC="${NGINX_RATE_LIMIT_STATIC:-100r/s}"
export NGINX_RATE_BURST_APP="${NGINX_RATE_BURST_APP:-20}"
export NGINX_RATE_BURST_STATIC="${NGINX_RATE_BURST_STATIC:-200}"
export NGINX_CLIENT_MAX_BODY_SIZE="${NGINX_CLIENT_MAX_BODY_SIZE:-1m}"

# Render template -> conf (only substituting our own vars, NOT nginx's $vars)
envsubst '${NGINX_SERVER_NAME}
  ${NGINX_RATE_LIMIT_APP}
  ${NGINX_RATE_LIMIT_STATIC}
  ${NGINX_RATE_BURST_APP}
  ${NGINX_RATE_BURST_STATIC}
  ${NGINX_CLIENT_MAX_BODY_SIZE}' \
  < /etc/nginx/templates/app.conf.template \
  > /etc/nginx/conf.d/app.conf

# Validate before starting
nginx -t

# Hand off to CMD (nginx -g 'daemon off;')
exec "$@"
