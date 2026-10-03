"""
Network Traffic Log Generator
Simulates normal and anomalous network traffic and stores it in MongoDB.
"""

import random
import time
import logging
from datetime import datetime
from pymongo import MongoClient
from pymongo.errors import ConnectionFailure

# ── Logging configuration ──────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

# ── MongoDB connection ─────────────────────────────────────────────────────
MONGO_URI = "mongodb://mongo1:27017/?replicaSet=rs0"
DB_NAME   = "network_logs"
COL_NAME  = "raw_logs"

# ── Traffic configuration ──────────────────────────────────────────────────
PROTOCOLS = ["TCP", "UDP", "ICMP", "HTTP", "HTTPS", "DNS"]

NORMAL_IPS = [f"192.168.1.{i}" for i in range(1, 50)]
ATTACK_IPS = ["10.0.0.99", "185.220.101.5", "45.33.32.156", "198.51.100.1"]

COMMON_PORTS    = [80, 443, 22, 53, 3306, 5432, 8080, 8443]
ANOMALY_TYPES   = ["port_scan", "ddos", "brute_force", "data_exfiltration"]


def connect_to_mongo(retries: int = 10, delay: int = 5) -> MongoClient:
    """Connect to MongoDB with exponential backoff retry."""
    for attempt in range(1, retries + 1):
        try:
            client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
            client.admin.command("ping")
            logger.info("Connected to MongoDB ✓")
            return client
        except ConnectionFailure as e:
            wait = delay * attempt
            logger.warning(f"Attempt {attempt}/{retries} failed. Retrying in {wait}s... ({e})")
            time.sleep(wait)
    raise RuntimeError("Could not connect to MongoDB after multiple attempts.")


def generate_normal_log() -> dict:
    """Generate a realistic normal network log entry."""
    return {
        "timestamp":        datetime.utcnow(),
        "source_ip":        random.choice(NORMAL_IPS),
        "destination_ip":   f"10.0.0.{random.randint(1, 254)}",
        "source_port":      random.randint(1024, 65535),
        "destination_port": random.choice(COMMON_PORTS),
        "protocol":         random.choice(PROTOCOLS),
        "bytes_sent":       random.randint(64, 1500),
        "packets":          random.randint(1, 10),
        "action":           "allow",
        "is_anomaly":       False,
        "anomaly_type":     None,
    }


def generate_anomaly_log(anomaly_type: str) -> dict:
    """Generate a simulated attack/anomaly log entry."""
    log = generate_normal_log()
    log["source_ip"]   = random.choice(ATTACK_IPS)
    log["is_anomaly"]  = True
    log["anomaly_type"] = anomaly_type

    if anomaly_type == "port_scan":
        log["destination_port"] = random.randint(1, 1024)
        log["packets"]          = random.randint(100, 500)
        log["action"]           = "deny"

    elif anomaly_type == "ddos":
        log["bytes_sent"] = random.randint(10000, 100000)
        log["packets"]    = random.randint(1000, 5000)
        log["protocol"]   = "UDP"
        log["action"]     = "deny"

    elif anomaly_type == "brute_force":
        log["destination_port"] = 22
        log["protocol"]         = "TCP"
        log["packets"]          = random.randint(50, 200)
        log["action"]           = "deny"

    elif anomaly_type == "data_exfiltration":
        log["bytes_sent"] = random.randint(50000, 500000)
        log["protocol"]   = "HTTPS"
        log["action"]     = "allow"

    return log


def run(interval: float = 1.0):
    """Main loop: generate and insert logs into MongoDB."""
    client     = connect_to_mongo()
    collection = client[DB_NAME][COL_NAME]

    # Create index on timestamp for better CDC performance
    collection.create_index("timestamp")
    logger.info(f"Inserting logs every {interval}s. Press Ctrl+C to stop.\n")

    count = 0
    try:
        while True:
            # 85% normal traffic / 15% anomalies
            if random.random() < 0.85:
                log = generate_normal_log()
            else:
                log = generate_anomaly_log(random.choice(ANOMALY_TYPES))

            collection.insert_one(log)
            count += 1

            label = f"[ANOMALY:{log['anomaly_type']}]" if log["is_anomaly"] else "[NORMAL]"
            logger.info(f"#{count:05d} {label} {log['source_ip']} → {log['destination_ip']}:{log['destination_port']} ({log['protocol']})")

            time.sleep(interval)

    except KeyboardInterrupt:
        logger.info(f"\nStopped. Total logs inserted: {count}")
    finally:
        client.close()


if __name__ == "__main__":
    run(interval=1.0)