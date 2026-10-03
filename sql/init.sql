-- ============================================
-- PostgreSQL Schema - Network Anomaly Platform
-- ============================================

-- Main table : raw network logs
CREATE TABLE IF NOT EXISTS network_logs (
    id              SERIAL PRIMARY KEY,
    timestamp       TIMESTAMP NOT NULL,
    source_ip       VARCHAR(45) NOT NULL,
    destination_ip  VARCHAR(45) NOT NULL,
    source_port     INTEGER,
    destination_port INTEGER,
    protocol        VARCHAR(10),
    bytes_sent      BIGINT DEFAULT 0,
    packets         INTEGER DEFAULT 1,
    action          VARCHAR(20) DEFAULT 'allow',
    created_at      TIMESTAMP DEFAULT NOW()
);

-- Detected anomalies table
CREATE TABLE IF NOT EXISTS anomalies (
    id              SERIAL PRIMARY KEY,
    detected_at     TIMESTAMP DEFAULT NOW(),
    source_ip       VARCHAR(45) NOT NULL,
    anomaly_type    VARCHAR(50) NOT NULL,
    severity        VARCHAR(20) DEFAULT 'medium',
    description     TEXT,
    log_count       INTEGER DEFAULT 1,
    resolved        BOOLEAN DEFAULT FALSE
);

-- Indexes for Grafana query performance
CREATE INDEX IF NOT EXISTS idx_logs_timestamp     ON network_logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_logs_source_ip     ON network_logs(source_ip);
CREATE INDEX IF NOT EXISTS idx_logs_protocol      ON network_logs(protocol);
CREATE INDEX IF NOT EXISTS idx_anomalies_type     ON anomalies(anomaly_type);
CREATE INDEX IF NOT EXISTS idx_anomalies_severity ON anomalies(severity);

-- View for SOC dashboard
CREATE OR REPLACE VIEW anomaly_summary AS
SELECT
    anomaly_type,
    severity,
    COUNT(*)         AS total,
    MAX(detected_at) AS last_seen
FROM anomalies
GROUP BY anomaly_type, severity
ORDER BY total DESC;