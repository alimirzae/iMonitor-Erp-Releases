#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_BASE="https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main"
CHANNEL="main"
ROOT_BASE="/opt/imonitor-erp"
HTTP_PORT=""
BIND_ADDRESS="0.0.0.0"
INSTALL_DOCKER=1

usage() {
  cat <<'EOF'
iMonitor ERP server installer/updater

Usage:
  Install-iMonitorERP-Server.sh [options]

Options:
  --channel main|test       Release channel (default: main)
  --port PORT               Override HTTP port (main 8080, test 8081)
  --bind ADDRESS            Bind address (default: 0.0.0.0)
  --root PATH               Installation root (default: /opt/imonitor-erp)
  --no-docker-install       Do not install Docker automatically
  -h, --help                Show this help

The script is idempotent: run the same command later to update the selected channel.
Persistent PostgreSQL, Redis and RabbitMQ volumes are preserved during updates.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --port) HTTP_PORT="${2:-}"; shift 2 ;;
    --bind) BIND_ADDRESS="${2:-}"; shift 2 ;;
    --root) ROOT_BASE="${2:-}"; shift 2 ;;
    --no-docker-install) INSTALL_DOCKER=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$CHANNEL" != "main" && "$CHANNEL" != "test" ]]; then
  echo "ERROR: --channel must be main or test." >&2
  exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root, for example: curl ... | sudo bash -s -- --channel $CHANNEL" >&2
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! need_cmd curl; then
  if need_cmd apt-get; then
    apt-get update -y && apt-get install -y curl ca-certificates
  elif need_cmd dnf; then
    dnf install -y curl ca-certificates
  elif need_cmd yum; then
    yum install -y curl ca-certificates
  else
    echo "ERROR: curl is required." >&2
    exit 1
  fi
fi

if ! need_cmd docker; then
  if [[ "$INSTALL_DOCKER" -ne 1 ]]; then
    echo "ERROR: Docker is not installed." >&2
    exit 1
  fi
  echo "Installing Docker Engine..."
  curl -fsSL https://get.docker.com | sh
fi

if need_cmd systemctl; then
  systemctl enable --now docker >/dev/null 2>&1 || true
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: Docker Compose v2 is required." >&2
  exit 1
fi

INSTALL_ROOT="${ROOT_BASE%/}/${CHANNEL}"
BACKUP_ROOT="${INSTALL_ROOT}/backups"
mkdir -p "$INSTALL_ROOT" "$BACKUP_ROOT"
cd "$INSTALL_ROOT"

CHANNEL_FILE="${INSTALL_ROOT}/channel.env"
COMPOSE_FILE="${INSTALL_ROOT}/compose.yml"
ENV_FILE="${INSTALL_ROOT}/.env"

curl -fsSL "$RELEASE_BASE/server/channels/${CHANNEL}.env" -o "$CHANNEL_FILE.tmp"
curl -fsSL "$RELEASE_BASE/server/compose.yml" -o "$COMPOSE_FILE.tmp"
mv "$CHANNEL_FILE.tmp" "$CHANNEL_FILE"
mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"

# shellcheck disable=SC1090
source "$CHANNEL_FILE"
if [[ -n "$HTTP_PORT" ]]; then
  IMONITOR_HTTP_PORT="$HTTP_PORT"
fi

random_secret() {
  if need_cmd openssl; then
    openssl rand -hex 24
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  fi
}

if [[ ! -f "$ENV_FILE" ]]; then
  umask 077
  cat > "$ENV_FILE" <<EOF
IMONITOR_CHANNEL=$CHANNEL
IMONITOR_IMAGE=$IMONITOR_IMAGE
IMONITOR_HTTP_PORT=$IMONITOR_HTTP_PORT
IMONITOR_BIND_ADDRESS=$BIND_ADDRESS
POSTGRES_DB=imonitor_erp
POSTGRES_USER=imonitor
POSTGRES_PASSWORD=$(random_secret)
RABBITMQ_USER=imonitor
RABBITMQ_PASSWORD=$(random_secret)
EOF
  chmod 600 "$ENV_FILE"
else
  # Preserve credentials and data settings, but follow the selected release channel.
  sed -i -E "s|^IMONITOR_CHANNEL=.*$|IMONITOR_CHANNEL=$CHANNEL|" "$ENV_FILE"
  sed -i -E "s|^IMONITOR_IMAGE=.*$|IMONITOR_IMAGE=$IMONITOR_IMAGE|" "$ENV_FILE"
  sed -i -E "s|^IMONITOR_HTTP_PORT=.*$|IMONITOR_HTTP_PORT=$IMONITOR_HTTP_PORT|" "$ENV_FILE"
  sed -i -E "s|^IMONITOR_BIND_ADDRESS=.*$|IMONITOR_BIND_ADDRESS=$BIND_ADDRESS|" "$ENV_FILE"
fi

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "imonitor-erp-$CHANNEL" "$@"
}

# Authenticate only when explicitly supplied. Public GHCR packages need no credentials.
if [[ -n "${GHCR_TOKEN:-}" ]]; then
  GHCR_USER="${GHCR_USER:-alimirzae}"
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
fi

# Best-effort database backup before an existing installation is upgraded.
if compose ps --status running postgres 2>/dev/null | grep -q postgres; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  echo "Creating PostgreSQL backup: $BACKUP_ROOT/postgres-$stamp.sql.gz"
  set -a; source "$ENV_FILE"; set +a
  if compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$BACKUP_ROOT/postgres-$stamp.sql.gz"; then
    echo "Backup completed."
  else
    rm -f "$BACKUP_ROOT/postgres-$stamp.sql.gz"
    echo "WARNING: database backup failed; update will continue because no schema migration is run by this installer yet." >&2
  fi
fi

echo "Pulling iMonitor ERP $CHANNEL containers..."
if ! compose pull; then
  echo >&2
  echo "ERROR: container pull failed." >&2
  echo "If ghcr.io/alimirzae/imonitor-erp is private, either make the package public or run with GHCR_TOKEN and GHCR_USER environment variables." >&2
  exit 1
fi

echo "Starting iMonitor ERP $CHANNEL stack..."
compose up -d --remove-orphans

HEALTH_URL="http://127.0.0.1:${IMONITOR_HTTP_PORT}/health"
echo "Waiting for $HEALTH_URL ..."
for _ in $(seq 1 60); do
  if curl -fsS "$HEALTH_URL" >/tmp/imonitor-health.json 2>/dev/null; then
    echo
    echo "[OK] iMonitor ERP $CHANNEL is healthy."
    cat /tmp/imonitor-health.json
    echo
    echo "Install root : $INSTALL_ROOT"
    echo "HTTP         : http://${BIND_ADDRESS}:${IMONITOR_HTTP_PORT}"
    echo "Update       : run this installer again with --channel $CHANNEL"
    echo "Status       : cd $INSTALL_ROOT && docker compose --env-file .env -f compose.yml -p imonitor-erp-$CHANNEL ps"
    exit 0
  fi
  sleep 2
done

echo "ERROR: health check timed out." >&2
compose ps >&2 || true
compose logs --tail=150 api >&2 || true
exit 1
