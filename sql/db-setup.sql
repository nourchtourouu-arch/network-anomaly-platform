-- =============================================================================
-- Companion script for "SOC - Network Anomaly Dashboard"
--   1. a read-only role for Grafana
--   2. indexes matching the dashboard's access paths
--
-- Idempotent, safe to re-run. Needs a role with CREATEROLE (to create grafana_ro)
-- and ownership of / GRANT OPTION on network_logs and anomalies.
--
--   docker exec -i postgres psql -v ON_ERROR_STOP=1 -U anomaly_user -d anomaly_db \
--     < sql/db-setup.sql
--
-- With the official "postgres" Docker image, POSTGRES_USER (here anomaly_user) is
-- created as a superuser by initdb, so the command above works unmodified. If you
-- swap in a managed/cloud Postgres later (RDS, Azure Database, Bitnami's image...)
-- the connecting user often does NOT have CREATEROLE, and the preflight check just
-- below stops with a clear message instead of failing on a later, more cryptic line.
--
-- Password, two ways:
--   - one-off / manual:  docker exec -it postgres psql -U anomaly_user -d anomaly_db \
--                           -c "\password grafana_ro"
--   - scripted / CI:      docker exec -i postgres psql -U anomaly_user -d anomaly_db \
--                           -v grafana_ro_password="$GRAFANA_RO_PASSWORD" < sql/db-setup.sql
--     (pass -v only when you actually want to (re)set the password non-interactively;
--     omitting it leaves any existing password untouched, so re-running this script
--     to pick up an index change never resets it by accident)
--
-- Adjust "public" below if your tables live in another schema.
-- =============================================================================

DO $$
BEGIN
  IF NOT (SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION E'current_user "%" cannot CREATE ROLE (needs CREATEROLE or superuser).\n'
      'Re-run this script as your Postgres superuser/admin account, or grant CREATEROLE '
      'to % first: ALTER ROLE % CREATEROLE;', current_user, current_user, current_user;
  END IF;
END
$$;

-- 1. Read-only role ------------------------------------------------------------
-- The real barrier is the privilege set (SELECT on two tables only).
-- The ALTER ROLE settings are defence in depth: a session can override them,
-- but without INSERT/UPDATE/DELETE grants it still cannot write.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
    CREATE ROLE grafana_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE CONNECTION LIMIT 10;
  END IF;
END
$$;

\if :{?grafana_ro_password}
  ALTER ROLE grafana_ro WITH PASSWORD :'grafana_ro_password';
  \echo 'grafana_ro password set from -v grafana_ro_password.'
\else
  \echo 'grafana_ro password left untouched (no -v grafana_ro_password given) — set one with: \password grafana_ro'
\endif

ALTER ROLE grafana_ro SET default_transaction_read_only = on;
ALTER ROLE grafana_ro SET statement_timeout = '15s';                  -- a "Last 90 days" click cannot hog the DB
ALTER ROLE grafana_ro SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE grafana_ro SET lock_timeout = '2s';

DO $$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO grafana_ro', current_database());
END
$$;
GRANT USAGE  ON SCHEMA public TO grafana_ro;
GRANT SELECT ON public.network_logs, public.anomalies TO grafana_ro;
-- PostgreSQL <= 14 only: schema "public" lets every role create objects.
-- Consider:  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
-- Prefer TLS with sslmode=verify-full in the Grafana data source, and a read replica if you have one.

-- 2. Indexes ---------------------------------------------------------------------
-- CONCURRENTLY avoids blocking writes (CDC keeps inserting) but cannot run inside a transaction.
-- TimescaleDB hypertable? It already indexes the time column: skip idx_network_logs_ts.

-- Every network_logs panel filters on the time column; MAX("timestamp") (Ingestion Lag) becomes an index probe.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_network_logs_ts
  ON public.network_logs ("timestamp" DESC);

-- Time-range filters and MAX(detected_at) on anomalies.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_anomalies_detected_at
  ON public.anomalies (detected_at DESC);

-- Open-incident tiles and queue: tiny partial index; the predicate matches "resolved IS NOT TRUE" exactly.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_anomalies_open
  ON public.anomalies (detected_at) WHERE resolved IS NOT TRUE;

-- Optional, for very large network_logs: a covering index enables index-only scans for the aggregate panels
-- (costs disk and write throughput; measure with EXPLAIN (ANALYZE, BUFFERS) before adopting).
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_network_logs_ts_cover
--   ON public.network_logs ("timestamp" DESC) INCLUDE (action, protocol, destination_port, bytes_sent);
