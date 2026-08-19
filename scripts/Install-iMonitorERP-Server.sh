#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_BASE="https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main"
CHANNEL="main"
ROOT_BASE="/opt/imonitor-erp"
HTTP_PORT=""
BIND_ADDRESS="0.0.0.0"
INSTALL_DOCKER=1
AUTO_UPDATE=1
UPDATE_MINUTES=5
ADMIN_USER="admin"
ADMIN_PASSWORD=""
COMPANY_CODE="DEFAULT"
COMPANY_NAME="Default Company"
BOOK_CODE="DEFAULT"
BOOK_NAME="Default Financial Book"

usage() {
  cat <<'EOF_HELP'
iMonitor ERP server installer/updater

Usage:
  Install-iMonitorERP-Server.sh [options]

Options:
  --channel main|test       Release channel (default: main)
  --port PORT               Override HTTP port (main 8080, test 8081)
  --bind ADDRESS            Bind address (default: 0.0.0.0)
  --root PATH               Installation root (default: /opt/imonitor-erp)
  --update-minutes N        Auto-update interval (default: 5)
  --no-auto-update          Do not install/update the systemd timer
  --no-docker-install       Do not install Docker automatically
  --admin-user USER         Initial administrator username (default: admin)
  --admin-password PASS     Initial administrator password; generated if omitted
  --company-code CODE       Initial company code
  --company-name NAME       Initial company name
  --book-code CODE          Initial financial book code
  --book-name NAME          Initial financial book name
  -h, --help                Show this help

The script is idempotent. PostgreSQL/Redis/RabbitMQ volumes and generated secrets are
preserved. Before an application update, PostgreSQL is backed up; Alembic migrations
run before the API container is started.
EOF_HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --port) HTTP_PORT="${2:-}"; shift 2 ;;
    --bind) BIND_ADDRESS="${2:-}"; shift 2 ;;
    --root) ROOT_BASE="${2:-}"; shift 2 ;;
    --update-minutes) UPDATE_MINUTES="${2:-}"; shift 2 ;;
    --no-auto-update) AUTO_UPDATE=0; shift ;;
    --no-docker-install) INSTALL_DOCKER=0; shift ;;
    --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="${2:-}"; shift 2 ;;
    --company-code) COMPANY_CODE="${2:-}"; shift 2 ;;
    --company-name) COMPANY_NAME="${2:-}"; shift 2 ;;
    --book-code) BOOK_CODE="${2:-}"; shift 2 ;;
    --book-name) BOOK_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$CHANNEL" != "main" && "$CHANNEL" != "test" ]]; then
  echo "ERROR: --channel must be main or test." >&2
  exit 2
fi
if ! [[ "$UPDATE_MINUTES" =~ ^[0-9]+$ ]] || [[ "$UPDATE_MINUTES" -lt 1 ]]; then
  echo "ERROR: --update-minutes must be a positive integer." >&2
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
MANIFEST_FILE="${INSTALL_ROOT}/manifest.json"
COMPOSE_FILE="${INSTALL_ROOT}/compose.yml"
ENV_FILE="${INSTALL_ROOT}/.env"
BOOTSTRAP_MARKER="${INSTALL_ROOT}/.core-bootstrapped"

curl -fsSL "$RELEASE_BASE/server/channels/${CHANNEL}.env" -o "$CHANNEL_FILE.tmp"
curl -fsSL "$RELEASE_BASE/server/channels/${CHANNEL}.json" -o "$MANIFEST_FILE.tmp"
curl -fsSL "$RELEASE_BASE/server/compose.yml" -o "$COMPOSE_FILE.tmp"
mv "$CHANNEL_FILE.tmp" "$CHANNEL_FILE"
mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"

# shellcheck disable=SC1090
source "$CHANNEL_FILE"
if [[ -n "$HTTP_PORT" ]]; then IMONITOR_HTTP_PORT="$HTTP_PORT"; fi

random_secret() {
  if need_cmd openssl; then openssl rand -hex 32; else tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64; fi
}

if [[ ! -f "$ENV_FILE" ]]; then
  umask 077
  cat > "$ENV_FILE" <<EOF_ENV
IMONITOR_CHANNEL=$CHANNEL
IMONITOR_IMAGE=$IMONITOR_IMAGE
IMONITOR_RELEASE_VERSION=${IMONITOR_RELEASE_VERSION:-rolling}
IMONITOR_SOURCE_SHA=${IMONITOR_SOURCE_SHA:-unknown}
IMONITOR_HTTP_PORT=$IMONITOR_HTTP_PORT
IMONITOR_BIND_ADDRESS=$BIND_ADDRESS
IMONITOR_NODE_PROFILE=cloud
IMONITOR_NODE_ID=$(hostname)-$CHANNEL
IMONITOR_JWT_SECRET=$(random_secret)
POSTGRES_DB=imonitor_erp
POSTGRES_USER=imonitor
POSTGRES_PASSWORD=$(random_secret)
RABBITMQ_USER=imonitor
RABBITMQ_PASSWORD=$(random_secret)
EOF_ENV
  chmod 600 "$ENV_FILE"
else
  sed -i -E "s|^IMONITOR_CHANNEL=.*$|IMONITOR_CHANNEL=$CHANNEL|" "$ENV_FILE"
  sed -i -E "s|^IMONITOR_IMAGE=.*$|IMONITOR_IMAGE=$IMONITOR_IMAGE|" "$ENV_FILE"
  sed -i -E "s|^IMONITOR_RELEASE_VERSION=.*$|IMONITOR_RELEASE_VERSION=${IMONITOR_RELEASE_VERSION:-rolling}|" "$ENV_FILE" || true
  sed -i -E "s|^IMONITOR_SOURCE_SHA=.*$|IMONITOR_SOURCE_SHA=${IMONITOR_SOURCE_SHA:-unknown}|" "$ENV_FILE" || true
  sed -i -E "s|^IMONITOR_HTTP_PORT=.*$|IMONITOR_HTTP_PORT=$IMONITOR_HTTP_PORT|" "$ENV_FILE"
  sed -i -E "s|^IMONITOR_BIND_ADDRESS=.*$|IMONITOR_BIND_ADDRESS=$BIND_ADDRESS|" "$ENV_FILE"
  grep -q '^IMONITOR_JWT_SECRET=' "$ENV_FILE" || echo "IMONITOR_JWT_SECRET=$(random_secret)" >> "$ENV_FILE"
  grep -q '^IMONITOR_NODE_PROFILE=' "$ENV_FILE" || echo 'IMONITOR_NODE_PROFILE=cloud' >> "$ENV_FILE"
  grep -q '^IMONITOR_NODE_ID=' "$ENV_FILE" || echo "IMONITOR_NODE_ID=$(hostname)-$CHANNEL" >> "$ENV_FILE"
fi

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "imonitor-erp-$CHANNEL" "$@"
}

if [[ -n "${GHCR_TOKEN:-}" ]]; then
  GHCR_USER="${GHCR_USER:-alimirzae}"
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
fi

if compose ps --status running postgres 2>/dev/null | grep -q postgres; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  echo "Creating PostgreSQL backup: $BACKUP_ROOT/postgres-$stamp.sql.gz"
  set -a; source "$ENV_FILE"; set +a
  if compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$BACKUP_ROOT/postgres-$stamp.sql.gz"; then
    find "$BACKUP_ROOT" -type f -name 'postgres-*.sql.gz' -mtime +14 -delete 2>/dev/null || true
  else
    rm -f "$BACKUP_ROOT/postgres-$stamp.sql.gz"
    echo "ERROR: database backup failed; refusing schema update." >&2
    exit 1
  fi
fi

echo "Pulling iMonitor ERP $CHANNEL image: $IMONITOR_IMAGE"
if ! compose pull api postgres redis rabbitmq; then
  echo "ERROR: container pull failed. If the GHCR package is private, provide GHCR_TOKEN/GHCR_USER." >&2
  exit 1
fi

compose up -d postgres redis rabbitmq
set -a; source "$ENV_FILE"; set +a
for _ in $(seq 1 60); do
  if compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then break; fi
  sleep 2
done
if ! compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
  echo "ERROR: PostgreSQL did not become ready." >&2
  exit 1
fi

echo "Applying database migrations..."
compose run --rm --no-deps api python -m alembic upgrade head

if [[ ! -f "$BOOTSTRAP_MARKER" ]]; then
  GENERATED_PASSWORD=0
  if [[ -z "$ADMIN_PASSWORD" ]]; then ADMIN_PASSWORD="$(random_secret | cut -c1-20)"; GENERATED_PASSWORD=1; fi
  echo "Creating initial ERP administrator/context..."
  compose run --rm --no-deps api python scripts/bootstrap_core.py \
    --company-code "$COMPANY_CODE" --company-name "$COMPANY_NAME" \
    --book-code "$BOOK_CODE" --book-name "$BOOK_NAME" \
    --username "$ADMIN_USER" --password "$ADMIN_PASSWORD"
  touch "$BOOTSTRAP_MARKER"
  chmod 600 "$BOOTSTRAP_MARKER"
  if [[ "$GENERATED_PASSWORD" -eq 1 ]]; then
    echo "IMPORTANT: generated initial admin credentials (shown once):"
    echo "  Username: $ADMIN_USER"
    echo "  Password: $ADMIN_PASSWORD"
  fi
fi

compose up -d --remove-orphans

install_auto_update() {
  [[ "$AUTO_UPDATE" -eq 1 ]] || return 0
  if need_cmd systemctl && [[ "$(cat /proc/1/comm 2>/dev/null || true)" == "systemd" ]]; then
    local service="/etc/systemd/system/imonitor-erp-${CHANNEL}-update.service"
    local timer="/etc/systemd/system/imonitor-erp-${CHANNEL}-update.timer"
    cat > "$service" <<EOF_SERVICE
[Unit]
Description=iMonitor ERP ${CHANNEL} automatic updater
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc 'curl -fsSL ${RELEASE_BASE}/scripts/Install-iMonitorERP-Server.sh | bash -s -- --channel ${CHANNEL} --port ${IMONITOR_HTTP_PORT} --bind ${BIND_ADDRESS} --root ${ROOT_BASE} --no-auto-update --no-docker-install'
EOF_SERVICE
    cat > "$timer" <<EOF_TIMER
[Unit]
Description=Check iMonitor ERP ${CHANNEL} updates

[Timer]
OnBootSec=2min
OnUnitActiveSec=${UPDATE_MINUTES}min
RandomizedDelaySec=30
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
    systemctl daemon-reload
    systemctl enable --now "imonitor-erp-${CHANNEL}-update.timer" >/dev/null
    echo "Auto-update: systemd timer every ${UPDATE_MINUTES} minute(s)."
  else
    echo "WARNING: systemd is not active; automatic update timer was not installed. Re-run this installer to update." >&2
  fi
}
install_auto_update

HEALTH_URL="http://127.0.0.1:${IMONITOR_HTTP_PORT}/health"
echo "Waiting for $HEALTH_URL ..."
for _ in $(seq 1 60); do
  if curl -fsS "$HEALTH_URL" >/tmp/imonitor-health.json 2>/dev/null; then
    echo "[OK] iMonitor ERP $CHANNEL is healthy."
    cat /tmp/imonitor-health.json; echo
    echo "Install root : $INSTALL_ROOT"
    echo "HTTP         : http://${BIND_ADDRESS}:${IMONITOR_HTTP_PORT}"
    echo "Release      : ${IMONITOR_RELEASE_VERSION:-rolling} (${IMONITOR_SOURCE_SHA:-unknown})"
    echo "Manifest     : $MANIFEST_FILE"
    exit 0
  fi
  sleep 2
done

echo "ERROR: health check timed out." >&2
compose ps >&2 || true
compose logs --tail=150 api >&2 || true
exit 1
