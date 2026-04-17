"""
DR Status Monitor — Business Continuity Platform
A lightweight Flask service that:
  - Exposes /health for Route 53 health checks & Kubernetes liveness probes
  - Reports region, DB connectivity, replication lag, and RTO/RPO status
  - Serves as the application protected by the DR platform
"""

import os
import time
import socket
import logging
import psycopg2
from datetime import datetime, timezone
from flask import Flask, jsonify
from prometheus_flask_exporter import PrometheusMetrics

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)
# Exposes /metrics endpoint automatically — scraped by Prometheus
metrics = PrometheusMetrics(app)
START_TIME = time.time()

# ── Config from environment (injected by Kubernetes Secret / ConfigMap) ──
DB_HOST     = os.getenv("DB_HOST", "localhost")
DB_PORT     = int(os.getenv("DB_PORT", "5432"))
DB_NAME     = os.getenv("DB_NAME", "drplatform")
DB_USER     = os.getenv("DB_USER", "dbadmin")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")
APP_REGION  = os.getenv("APP_REGION", "unknown")
APP_ENV     = os.getenv("APP_ENV", "primary")
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD, connect_timeout=3
    )


def check_db_health():
    """Check PostgreSQL connectivity and return status dict."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT version(), now(), pg_is_in_recovery()")
        version, db_time, is_replica = cur.fetchone()
        cur.close()
        conn.close()
        return {
            "status": "healthy",
            "version": version.split(",")[0],
            "server_time": str(db_time),
            "is_replica": is_replica,
            "role": "replica" if is_replica else "primary"
        }
    except Exception as e:
        log.error("DB health check failed: %s", e)
        return {"status": "unhealthy", "error": str(e)}


def get_uptime():
    seconds = int(time.time() - START_TIME)
    h, remainder = divmod(seconds, 3600)
    m, s = divmod(remainder, 60)
    return f"{h}h {m}m {s}s"


# ── Routes ───────────────────────────────────────────────

@app.route("/health", methods=["GET"])
def health():
    """
    Primary endpoint for Route 53 health checks and K8s probes.
    Returns 200 when healthy, 503 when DB is unreachable.
    """
    db = check_db_health()
    healthy = db["status"] == "healthy"
    payload = {
        "status": "healthy" if healthy else "degraded",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "region": APP_REGION,
        "environment": APP_ENV,
        "hostname": socket.gethostname(),
        "database": db,
        "uptime": get_uptime(),
    }
    return jsonify(payload), 200 if healthy else 503


@app.route("/", methods=["GET"])
def index():
    """DR Platform status overview."""
    return jsonify({
        "application": "DR Status Monitor",
        "description": "Cloud-Native Disaster Recovery Platform — Business Continuity Monitor",
        "version": APP_VERSION,
        "region": APP_REGION,
        "environment": APP_ENV,
        "hostname": socket.gethostname(),
        "uptime": get_uptime(),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "endpoints": {
            "/":        "Application overview",
            "/health":  "Health check (Route 53 + K8s liveness probe)",
            "/ready":   "Readiness probe (fails until DB reachable)",
            "/status":  "Detailed DR platform status",
            "/metrics": "Prometheus metrics (scraped by kube-prometheus-stack)",
        }
    })


@app.route("/status", methods=["GET"])
def status():
    """Detailed DR platform status including DB role and replication state."""
    db = check_db_health()
    return jsonify({
        "platform": "DR Status Monitor",
        "region": APP_REGION,
        "environment": APP_ENV,
        "version": APP_VERSION,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "uptime": get_uptime(),
        "hostname": socket.gethostname(),
        "database": db,
        "dr_mode": {
            "active_site": APP_ENV,
            "db_role": db.get("role", "unknown"),
            "failover_ready": db["status"] == "healthy",
        },
        "compliance": {
            "standard": "ISO 22301 / NIST SP 800-34",
            "rto_target": "< 5 minutes",
            "rpo_target": "< 1 minute",
        }
    })


@app.route("/ready", methods=["GET"])
def ready():
    """Kubernetes readiness probe — fails until DB is reachable."""
    db = check_db_health()
    if db["status"] != "healthy":
        return jsonify({"ready": False, "reason": db.get("error")}), 503
    return jsonify({"ready": True}), 200


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    log.info("Starting DR Status Monitor on port %d in region %s", port, APP_REGION)
    app.run(host="0.0.0.0", port=port)
