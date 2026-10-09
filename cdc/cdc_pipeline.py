"""
CDC Pipeline - Change Data Capture
Watches MongoDB change streams and replicates data to PostgreSQL.

Resilience notes:
- The resume token is persisted to disk after every processed change, so a
  restart (crash, OOM, `docker restart`) resumes the stream from the last
  acknowledged position instead of silently skipping whatever happened while
  the process was down.
- Each insert is wrapped in its own try/except: a single bad document (a
  constraint violation, an unexpected type) is logged and skipped rather than
  crashing the whole process and losing the in-memory stream position.
- A lightweight background pass periodically marks old anomalies as resolved,
  so a long-running demo doesn't show the exact same open incidents forever.
- A Slack alert is sent for each high-severity anomaly, throttled to avoid
  flooding the channel. It is fully optional: with no SLACK_WEBHOOK_URL set,
  alerting is skipped with no error and no retries.
"""

import os
import json
import time
import logging
import threading
import urllib.request
import urllib.error
import psycopg2
from pymongo import MongoClient
from pymongo.errors import PyMongoError

# ── Logging configuration ──────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

# ── Connection settings ────────────────────────────────────────────────────
MONGO_URI = "mongodb://mongo1:27017/?replicaSet=rs0"
PG_CONFIG = {
    "host":     "postgres",
    "port":     5432,
    "dbname":   os.environ["POSTGRES_DB"],
    "user":     os.environ["POSTGRES_USER"],
    "password": os.environ["POSTGRES_PASSWORD"],
}

DB_NAME  = "network_logs"
COL_NAME = "raw_logs"

RESUME_TOKEN_PATH = "/app/state/resume_token.json"

# Anomaly type → severity. "low" exists on purpose, so the dashboard's
# severity filter reflects real variety instead of only high/medium.
SEVERITY_MAP = {
    "ddos":               "high",
    "data_exfiltration":  "high",
    "brute_force":        "medium",
    "port_scan":          "low",
}

# How old an open anomaly must be before the background pass auto-resolves
# it, purely to keep a long-running demo dashboard from looking static.
AUTO_RESOLVE_AFTER_MINUTES = 30
AUTO_RESOLVE_INTERVAL_SECONDS = 60

# ── Slack alerting (optional) ──────────────────────────────────────────────
# An unset SLACK_WEBHOOK_URL disables alerting entirely — no error, no
# retries — so the pipeline stays fully functional on a fresh checkout
# where no Slack workspace has been configured yet.
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "").strip()
SLACK_ALERT_SEVERITIES = {"high"}

# Minimum time between two Slack messages. The synthetic generator can
# produce a burst of dozens of high-severity anomalies within seconds;
# without a floor, a single burst would flood the channel and risk hitting
# Slack's own rate limit. One alert per burst is enough to notify a human —
# the dashboard stays the source of truth for the full incident count.
SLACK_MIN_INTERVAL_SECONDS = 10


# ── PostgreSQL connection ──────────────────────────────────────────────────
def connect_postgres(retries: int = 10, delay: int = 5):
    """Connect to PostgreSQL with retry logic."""
    for attempt in range(1, retries + 1):
        try:
            conn = psycopg2.connect(**PG_CONFIG)
            conn.autocommit = False
            logger.info("Connected to PostgreSQL ✓")
            return conn
        except psycopg2.OperationalError as e:
            wait = delay * attempt
            logger.warning(f"Attempt {attempt}/{retries} failed. Retrying in {wait}s... ({e})")
            time.sleep(wait)
    raise RuntimeError("Could not connect to PostgreSQL after multiple attempts.")


# ── MongoDB connection ─────────────────────────────────────────────────────
def connect_mongo(retries: int = 10, delay: int = 5) -> MongoClient:
    """Connect to MongoDB with retry logic."""
    for attempt in range(1, retries + 1):
        try:
            client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
            client.admin.command("ping")
            logger.info("Connected to MongoDB ✓")
            return client
        except Exception as e:
            wait = delay * attempt
            logger.warning(f"Attempt {attempt}/{retries} failed. Retrying in {wait}s... ({e})")
            time.sleep(wait)
    raise RuntimeError("Could not connect to MongoDB after multiple attempts.")


# ── Resume token persistence ───────────────────────────────────────────────
def load_resume_token():
    """Load the last processed resume token from disk, if any."""
    try:
        with open(RESUME_TOKEN_PATH, "r") as f:
            token = json.load(f)
            logger.info(f"Resuming change stream from saved token: {token}")
            return token
    except FileNotFoundError:
        logger.info("No saved resume token found — starting from the current position.")
        return None
    except (json.JSONDecodeError, OSError) as e:
        logger.warning(f"Could not read resume token ({e}) — starting from the current position.")
        return None


def save_resume_token(token):
    """Persist the resume token to disk after each processed change."""
    try:
        os.makedirs(os.path.dirname(RESUME_TOKEN_PATH), exist_ok=True)
        with open(RESUME_TOKEN_PATH, "w") as f:
            json.dump(token, f)
    except OSError as e:
        logger.warning(f"Could not persist resume token: {e}")


# ── Insert log into PostgreSQL ─────────────────────────────────────────────
def insert_log(cursor, doc: dict):
    """Insert a network log document into PostgreSQL."""
    cursor.execute("""
        INSERT INTO network_logs
            (timestamp, source_ip, destination_ip,
             source_port, destination_port, protocol,
             bytes_sent, packets, action)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
    """, (
        doc.get("timestamp"),
        doc.get("source_ip"),
        doc.get("destination_ip"),
        doc.get("source_port"),
        doc.get("destination_port"),
        doc.get("protocol"),
        doc.get("bytes_sent", 0),
        doc.get("packets", 1),
        doc.get("action", "allow"),
    ))


# ── Insert anomaly into PostgreSQL ─────────────────────────────────────────
def insert_anomaly(cursor, doc: dict) -> str:
    """Insert a detected anomaly into PostgreSQL. Returns the assigned severity."""
    anomaly_type = doc.get("anomaly_type")
    severity = SEVERITY_MAP.get(anomaly_type, "medium")

    cursor.execute("""
        INSERT INTO anomalies
            (detected_at, source_ip, anomaly_type, severity, description)
        VALUES (%s, %s, %s, %s, %s)
    """, (
        doc.get("timestamp"),
        doc.get("source_ip"),
        anomaly_type,
        severity,
        f"Detected {anomaly_type} from {doc.get('source_ip')}",
    ))

    return severity


# ── Slack alerting ──────────────────────────────────────────────────────────
_last_slack_alert_ts = 0.0
_slack_lock = threading.Lock()


def send_slack_alert(anomaly_type: str, source_ip: str, severity: str, detected_at) -> None:
    """
    Post a one-line alert to Slack for a high-severity anomaly.

    Fails silently (logged as a warning) on any network or Slack-side error:
    a misconfigured or unreachable webhook must never interrupt replication,
    which is the pipeline's actual job. Throttled to at most one message
    every SLACK_MIN_INTERVAL_SECONDS to avoid flooding the channel when the
    generator produces a burst of anomalies in a short window.
    """
    if not SLACK_WEBHOOK_URL:
        return

    global _last_slack_alert_ts
    with _slack_lock:
        now = time.time()
        if now - _last_slack_alert_ts < SLACK_MIN_INTERVAL_SECONDS:
            return
        _last_slack_alert_ts = now

    payload = {
        "text": (
            f":rotating_light: *High-severity anomaly detected*\n"
            f"• *Type:* `{anomaly_type}`\n"
            f"• *Source IP:* `{source_ip}`\n"
            f"• *Severity:* `{severity}`\n"
            f"• *Detected at:* {detected_at} UTC"
        )
    }
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=data,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            if response.status >= 300:
                logger.warning(f"[slack] Unexpected response status: {response.status}")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        logger.warning(f"[slack] Failed to send alert: {e}")


# ── Background auto-resolve pass ───────────────────────────────────────────
def auto_resolve_loop():
    """
    Periodically marks old open anomalies as resolved.

    This is a demo convenience, not a real resolution workflow: nothing in
    this project currently evaluates whether an incident was actually
    handled. It exists so a dashboard left running for a while shows a
    queue that moves, instead of the exact same rows forever.
    """
    conn = connect_postgres()
    try:
        while True:
            time.sleep(AUTO_RESOLVE_INTERVAL_SECONDS)
            try:
                with conn.cursor() as cursor:
                    cursor.execute("""
                        UPDATE anomalies
                        SET resolved = TRUE
                        WHERE resolved IS NOT TRUE
                          AND detected_at < NOW() - (%s * INTERVAL '1 minute')
                    """, (AUTO_RESOLVE_AFTER_MINUTES,))
                    resolved_count = cursor.rowcount
                conn.commit()
                if resolved_count:
                    logger.info(f"[auto-resolve] Marked {resolved_count} old anomalies as resolved")
            except psycopg2.Error as e:
                conn.rollback()
                logger.warning(f"[auto-resolve] Skipped this pass due to a database error: {e}")
    finally:
        conn.close()


# ── Main CDC loop ──────────────────────────────────────────────────────────
def run():
    """Watch MongoDB change stream and replicate to PostgreSQL."""
    mongo_client = connect_mongo()
    pg_conn      = connect_postgres()
    collection   = mongo_client[DB_NAME][COL_NAME]

    resume_token = load_resume_token()

    threading.Thread(target=auto_resolve_loop, daemon=True).start()

    logger.info("Watching MongoDB change stream... Press Ctrl+C to stop.\n")

    count = 0
    skipped = 0

    watch_kwargs = {"resume_after": resume_token} if resume_token else {}

    try:
        with collection.watch(
            [{"$match": {"operationType": "insert"}}],
            **watch_kwargs
        ) as stream:
            for change in stream:
                doc = change.get("fullDocument", {})

                severity = None

                try:
                    with pg_conn.cursor() as cursor:
                        insert_log(cursor, doc)
                        if doc.get("is_anomaly"):
                            severity = insert_anomaly(cursor, doc)
                    pg_conn.commit()

                except psycopg2.Error as e:
                    # A single bad document must not take down the whole
                    # pipeline. Roll back just this transaction, log it,
                    # and move on to the next change.
                    pg_conn.rollback()
                    skipped += 1
                    logger.error(f"Skipped one document due to a database error: {e}")

                else:
                    count += 1
                    label = f"[ANOMALY:{doc.get('anomaly_type')}]" if doc.get("is_anomaly") else "[NORMAL]"
                    logger.info(f"#{count:05d} {label} replicated → PostgreSQL")

                    # Only alert on anomalies that were actually committed —
                    # never on a document that failed to persist.
                    if severity in SLACK_ALERT_SEVERITIES:
                        send_slack_alert(
                            doc.get("anomaly_type"),
                            doc.get("source_ip"),
                            severity,
                            doc.get("timestamp"),
                        )

                # Persist the resume token after every change, successful or
                # not, so a restart never reprocesses or silently skips
                # more than the single change currently in flight.
                save_resume_token(stream.resume_token)

    except KeyboardInterrupt:
        logger.info(f"\nStopped. Replicated: {count} | Skipped: {skipped}")
    except PyMongoError as e:
        logger.error(f"MongoDB error: {e}")
    finally:
        pg_conn.close()
        mongo_client.close()


if __name__ == "__main__":
    run()
