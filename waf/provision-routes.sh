#!/usr/bin/env bash
#
# Provisions the WAF routes described in waf/apisix.yaml into etcd via the
# APISIX Admin API.
#
# Why this script exists: APISIX runs in `traditional` mode (etcd as the
# config store). In that mode, conf/apisix.yaml is a file APISIX never
# reads at runtime -- it's config_provider: yaml (standalone mode) that
# reads it, and this deployment deliberately does not use that mode (see
# README > Security Considerations). So the routes in that file are only a
# human-readable reference; this script is what actually makes them live.
#
# Idempotent: every call is a PUT to a fixed resource ID, so re-running
# this script simply re-applies the same config. Safe to run as many
# times as you want.
#
# Usage:
#   set -a; source .env; set +a
#   ./waf/provision-routes.sh

set -euo pipefail

ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
ADMIN_KEY="${APISIX_ADMIN_KEY:?APISIX_ADMIN_KEY is not set. Run: set -a; source .env; set +a}"

put() {
  local path="$1"
  local body="$2"
  local response_file
  response_file="$(mktemp)"

  local code
  code=$(curl -s -o "$response_file" -w "%{http_code}" \
    -X PUT "${ADMIN_URL}${path}" \
    -H "X-API-KEY: ${ADMIN_KEY}" \
    -H "Content-Type: application/json" \
    -d "${body}")

  if [[ "$code" == 2* ]]; then
    echo "OK    ${path} (HTTP ${code})"
  else
    echo "FAIL  ${path} (HTTP ${code})"
    cat "$response_file"
    echo
    rm -f "$response_file"
    exit 1
  fi
  rm -f "$response_file"
}

echo "--- Upstream: backend (placeholder -- this demo proves the WAF layer," \
     "not a real backend; passed requests will 502, which is expected) ---"
put "/apisix/admin/upstreams/1" '{
  "id": "1",
  "type": "roundrobin",
  "nodes": { "127.0.0.1:8080": 1 }
}'

echo "--- Route 1: protected-route (rate limit + path/IP blocking) ---"
put "/apisix/admin/routes/1" '{
  "id": "1",
  "uri": "/*",
  "name": "protected-route",
  "upstream_id": "1",
  "plugins": {
    "limit-count": {
      "count": 100,
      "time_window": 60,
      "key": "remote_addr",
      "rejected_code": 429,
      "rejected_msg": "Too many requests - possible DDoS detected"
    },
    "uri-blocker": {
      "block_rules": [
        ".*\\.php$",
        ".*\\.asp$",
        ".*etc/passwd.*",
        ".*union.*select.*",
        ".*<script>.*",
        ".*\\.\\./.*"
      ],
      "rejected_code": 403
    },
    "ip-restriction": {
      "blacklist": [
        "10.0.0.99",
        "185.220.101.5",
        "45.33.32.156",
        "198.51.100.1"
      ],
      "message": "Your IP has been blocked - suspicious activity detected"
    },
    "prometheus": {}
  }
}'

echo "--- Route 2: health-check ---"
put "/apisix/admin/routes/2" '{
  "id": "2",
  "uri": "/health",
  "name": "health-check",
  "upstream_id": "1",
  "plugins": {
    "prometheus": {}
  }
}'

echo
echo "Done. Routes are live in etcd and enforced by the gateway at :9080."
