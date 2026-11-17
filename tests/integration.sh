#!/usr/bin/env bash
# Integration test for the MongoDB -> CDC -> PostgreSQL pipeline.
#
# What it proves, on a real docker compose stack:
#   1. the MongoDB replica set initialises, and re-running mongo-init is a no-op
#      (exit 0, no restart loop);
#   2. documents inserted by the generator reach PostgreSQL, with fresh data and
#      the expected severities;
#   3. the CDC resumes from its saved token after a restart: nothing inserted
#      while it was down is lost or duplicated.
#
# It ends with `docker compose down -v` (deletes the stack's volumes), so it only
# runs in CI (CI=true). To run it locally, opt in with ALLOW_LOCAL=1, on a
# throw-away checkout with your own stack stopped.
set -euo pipefail

if [ "${CI:-}" != "true" ] && [ "${ALLOW_LOCAL:-}" != "1" ]; then
  echo "Refusing to run: this test finishes with 'docker compose down -v', which deletes volumes." >&2
  echo "Run it in CI, or set ALLOW_LOCAL=1 (stop your own stack first)." >&2
  exit 2
fi

cd "$(dirname "$0")/.."
[ -f .env ] || cp .env.example .env

log()  { echo "==> $*"; }
fail() { echo "::error::$*" >&2; exit 1; }

# Run a SQL query inside the postgres container (user and database come from its own env).
pg() { docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "$1"' _ "$1"; }

# Number of documents in the source collection.
mongo_count() {
  docker compose exec -T mongo1 mongosh --quiet \
    --eval 'db.getSiblingDB("network_logs").raw_logs.countDocuments({})' | tail -n 1 | tr -d '[:space:]'
}

dump_logs() {
  echo "::group::docker compose ps"; docker compose ps -a || true; echo "::endgroup::"
  for s in mongo-init cdc generator postgres mongo1; do
    echo "::group::logs: $s"; docker compose logs --no-color --tail=60 "$s" || true; echo "::endgroup::"
  done
}

cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ]; then dump_logs; fi
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

# wait_for "<description>" <timeout_seconds> <command...>
wait_for() {
  local desc=$1 timeout=$2 waited=0
  shift 2
  until "$@"; do
    waited=$((waited + 3))
    [ "$waited" -le "$timeout" ] || fail "Timed out after ${timeout}s: ${desc}"
    sleep 3
  done
  log "OK: ${desc} (after ~${waited}s)"
}

# Echoes the PostgreSQL row count once it has not moved for ~6 seconds.
wait_stable() {
  local prev=-1 same=0 cur waited=0
  while [ "$same" -lt 3 ]; do
    cur=$(pg 'SELECT COUNT(*) FROM network_logs')
    if [ "$cur" = "$prev" ]; then same=$((same + 1)); else same=0; prev=$cur; fi
    waited=$((waited + 2))
    [ "$waited" -le 90 ] || fail "PostgreSQL row count never stabilised"
    sleep 2
  done
  echo "$prev"
}

mongo_init_ok()   { [ "$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' mongo-init 2>/dev/null)" = "exited 0" ]; }
rows_replicated() { [ "$(pg 'SELECT COUNT(*) FROM network_logs' 2>/dev/null)" -ge 15 ] && [ "$(pg 'SELECT COUNT(*) FROM anomalies' 2>/dev/null)" -ge 1 ]; }
count_above()     { [ "$(pg 'SELECT COUNT(*) FROM network_logs' 2>/dev/null)" -gt "$1" ]; }

# ── 1. MongoDB replica set ───────────────────────────────────────────────────
log "Starting the stack: mongo, postgres, cdc, generator"
docker compose up -d --build mongo1 mongo-init postgres cdc generator

log "1/4 MongoDB replica set"
wait_for "mongo-init finished with exit code 0" 150 mongo_init_ok

log "Re-running mongo-init against the already-initialised replica set"
docker compose up -d --force-recreate --no-deps mongo-init
wait_for "mongo-init re-run finished with exit code 0" 60 mongo_init_ok
[ "$(docker inspect -f '{{.RestartCount}}' mongo-init)" = "0" ] || fail "mongo-init restarted: it is not idempotent"

# ── 2. Replication ───────────────────────────────────────────────────────────
log "2/4 Replication MongoDB -> PostgreSQL"
wait_for "at least 15 logs and 1 anomaly in PostgreSQL" 180 rows_replicated

fresh="$(pg "SELECT (NOW() - MAX(created_at)) < INTERVAL '30 seconds' FROM network_logs")"
[ "$fresh" = "t" ] || fail "the newest PostgreSQL row is older than 30 seconds while the generator is running"

bad="$(pg "SELECT COUNT(*) FROM anomalies WHERE (anomaly_type IN ('ddos','data_exfiltration') AND severity <> 'high') OR (anomaly_type = 'brute_force' AND severity <> 'medium') OR (anomaly_type = 'port_scan' AND severity <> 'low')")"
[ "$bad" = "0" ] || fail "${bad} anomalies have a severity that does not match their type"

# ── 3. CDC restart: no loss, no duplicates ───────────────────────────────────
log "3/4 CDC restart: nothing inserted while it is down may be lost or duplicated"
docker compose stop generator
pg0="$(wait_stable)"
m0="$(mongo_count)"
gap0=$((m0 - pg0))
log "before the restart: mongo=${m0} postgres=${pg0} (gap ${gap0}: documents inserted before the CDC started watching)"
[ "$gap0" -ge 0 ] || fail "PostgreSQL has more rows than MongoDB before any restart"
docker compose exec -T cdc test -s /app/state/resume_token.json || fail "the CDC did not persist a resume token"

docker compose stop cdc
docker compose start generator
sleep 15
docker compose stop generator
m1="$(mongo_count)"
inserted=$((m1 - m0))
[ "$inserted" -ge 5 ] || fail "the generator inserted only ${inserted} documents while the CDC was down"
log "${inserted} documents were inserted while the CDC was down"

docker compose start cdc
wait_for "the CDC resumed replication (PostgreSQL count above ${pg0})" 90 count_above "$pg0"
pg1="$(wait_stable)"
gap1=$((m1 - pg1))
[ "$gap1" -eq "$gap0" ] || fail "after the restart: mongo=${m1} postgres=${pg1}; the gap is ${gap1}, expected ${gap0} (lost or duplicated documents)"
log "OK: mongo=${m1} postgres=${pg1}, the gap is unchanged (${gap1})"

# ── 4. Final health ──────────────────────────────────────────────────────────
log "4/4 Final health"
[ "$(docker inspect -f '{{.State.Running}}' cdc)" = "true" ] || fail "the cdc container is not running"
cdc_logs="$(docker compose logs --no-color cdc)"
if grep -q "Skipped one document" <<<"$cdc_logs"; then
  fail "the CDC skipped documents because of database errors"
fi

log "All integration checks passed"
