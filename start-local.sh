#!/usr/bin/env bash
# Start Bisheng frontend + backend locally on Windows (Git Bash) / Linux / macOS.
#
# Prerequisites:
#   - Middleware (MySQL, Redis, MinIO, ES, Milvus, OpenFGA) running in Docker.
#   - Backend venv:  cd src/backend && uv sync --frozen --python 3.11
#   - Frontend deps: cd src/frontend && pnpm install --frozen-lockfile
#
# Usage:
#   bash start-local.sh                 # frontend + backend
#   bash start-local.sh --with-workers  # also Celery (knowledge/workflow/beat) + Linsight
#   Ctrl+C stops everything this script started.
#
# Logs: logs/local/{backend,frontend-platform,frontend-client,workers}.log
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

WITH_WORKERS=false
for arg in "$@"; do
  case "$arg" in
    --with-workers) WITH_WORKERS=true ;;
    -h|--help)
      sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

LOG_DIR="$ROOT/logs/local"
mkdir -p "$LOG_DIR"
BACKEND_LOG="$LOG_DIR/backend.log"
PLATFORM_LOG="$LOG_DIR/frontend-platform.log"
CLIENT_LOG="$LOG_DIR/frontend-client.log"
WORKERS_LOG="$LOG_DIR/workers.log"

is_listening() {
  netstat -ano 2>/dev/null | grep -E "LISTENING" | grep -q ":$1 "
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

echo "== Bisheng local dev =="
echo "root: $ROOT"
echo

# ---- prerequisites ---------------------------------------------------------
if [ -x "$ROOT/src/backend/.venv/Scripts/python.exe" ]; then
  PY="$ROOT/src/backend/.venv/Scripts/python.exe"
elif [ -x "$ROOT/src/backend/.venv/bin/python" ]; then
  PY="$ROOT/src/backend/.venv/bin/python"
else
  fail "backend venv missing. Run: cd src/backend && uv sync --frozen --python 3.11"
fi

command -v pnpm >/dev/null 2>&1 || fail "pnpm not found. Run: npm i -g pnpm@9.15.9"
[ -d "$ROOT/src/frontend/node_modules" ] || fail "frontend deps missing. Run: cd src/frontend && pnpm install --frozen-lockfile"

# ---- local environment -----------------------------------------------------
export PYTHONPATH="$ROOT/src/backend${PYTHONPATH:+:$PYTHONPATH}"
export BISHENG_GATEWAY_HMAC_SECRET="${BISHENG_GATEWAY_HMAC_SECRET:-}"
export BS_MILVUS_CONNECTION_ARGS='{"host":"127.0.0.1","port":"29530","user":"","password":"","secure":false}'
export BS_MILVUS_IS_PARTITION=true
export BS_MILVUS_PARTITION_SUFFIX=1
export BS_ELASTICSEARCH_URL=http://127.0.0.1:19200
export BS_ELASTICSEARCH_SSL_VERIFY='{}'
export BS_MINIO_SCHEMA=false
export BS_MINIO_CERT_CHECK=false
export BS_MINIO_ENDPOINT=127.0.0.1:19100
export BS_MINIO_SHAREPOINT=127.0.0.1:19100
export BS_MINIO_ACCESS_KEY=minioadmin
export BS_MINIO_SECRET_KEY=minioadmin

# ---- port checks -----------------------------------------------------------
for port in 17860 13001 14001; do
  if is_listening "$port"; then
    fail "port $port is already in use. Stop the existing process (or the Docker app containers) first."
  fi
done

# ---- cleanup ---------------------------------------------------------------
cleanup() {
  trap - INT TERM EXIT
  echo
  echo "Stopping local processes..."
  for pid in "${WORKERS_PID:-}" "${CLIENT_PID:-}" "${PLATFORM_PID:-}" "${BACKEND_PID:-}"; do
    [ -n "$pid" ] || continue
    if command -v taskkill >/dev/null 2>&1; then
      taskkill //F //T //PID "$pid" >/dev/null 2>&1 || true
    else
      kill "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup INT TERM EXIT

# ---- start -----------------------------------------------------------------
echo "Starting backend   -> http://localhost:17860"
( cd "$ROOT/src/backend" && "$PY" -m uvicorn bisheng.main:app --host 0.0.0.0 --port 17860 --workers 1 --reload ) > "$BACKEND_LOG" 2>&1 &
BACKEND_PID=$!

echo "Starting platform  -> http://localhost:13001"
( cd "$ROOT/src/frontend" && pnpm dev:platform ) > "$PLATFORM_LOG" 2>&1 &
PLATFORM_PID=$!

echo "Starting client    -> http://localhost:14001/workspace/__dev/login"
( cd "$ROOT/src/frontend" && pnpm dev:client ) > "$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!

if [ "$WITH_WORKERS" = true ]; then
  echo "Starting workers   -> knowledge/workflow/beat + Linsight (log: $WORKERS_LOG)"
  (
    cd "$ROOT/src/backend"
    # A stale/killed beat process leaves an inconsistent schedule DB behind.
    rm -f celerybeat-schedule celerybeat-schedule.*
    "$PY" -m celery -A bisheng.worker.main worker -l info -c 50 -P threads -Q knowledge_celery -n knowledge@%h &
    "$PY" -m celery -A bisheng.worker.main worker -l info -c 100 -P threads -Q workflow_celery -n workflow@%h &
    "$PY" -m celery -A bisheng.worker.main beat -l info &
    "$PY" bisheng/linsight/worker.py --worker_num 1 --max_concurrency 5 &
    wait
  ) > "$WORKERS_LOG" 2>&1 &
  WORKERS_PID=$!
fi

cat <<EOF

Logs:
  $BACKEND_LOG
  $PLATFORM_LOG
  $CLIENT_LOG
$([ "$WITH_WORKERS" = true ] && echo "  $WORKERS_LOG")

URLs:
  Platform: http://localhost:13001
  Client:   http://localhost:14001/workspace/__dev/login
  API:      http://localhost:17860/health

Press Ctrl+C to stop everything this script started.
EOF

wait
