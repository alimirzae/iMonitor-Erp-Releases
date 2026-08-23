#!/usr/bin/env bash
set -euo pipefail

INSTALLER_VERSION="1.0.0"
RELEASE_REPO="alimirzae/iMonitor-Erp-Releases"
PRODUCT_ROOT="/opt/imonitor-platform"
STATE_ROOT="/var/lib/imonitor-platform"
CONFIG_ROOT="/etc/imonitor-platform"
COMPOSE_PROJECT_NAME="imonitor"
UPDATE_ONLY=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --update-only) UPDATE_ONLY=1 ;;
    --force) FORCE=1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run with sudo/root."; exit 1; }

log(){ printf '\n[iMonitor] %s\n' "$*"; }
need(){ command -v "$1" >/dev/null 2>&1; }

install_base_deps(){
  if need apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl jq tar gzip openssl coreutils
    if ! need docker; then apt-get install -y docker.io; fi
    if ! docker compose version >/dev/null 2>&1; then
      apt-get install -y docker-compose-v2 2>/dev/null || apt-get install -y docker-compose-plugin 2>/dev/null || apt-get install -y docker-compose
    fi
  else
    echo "This installer currently supports Debian/Ubuntu Linux." >&2
    exit 2
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
}

compose(){
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

release_json(){
  curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${RELEASE_REPO}/releases?per_page=100&cachebust=$(date +%s)" |
    jq -c '[.[] | select(.draft==false and (.tag_name|startswith("imonitor-platform-v")))] | sort_by(.published_at) | last'
}

asset_url(){ local json="$1" name="$2"; jq -r --arg n "$name" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$json" | head -n1; }

install_base_deps
mkdir -p "$PRODUCT_ROOT/releases" "$STATE_ROOT/installers" "$CONFIG_ROOT"

REL="$(release_json)"
[[ "$REL" != "null" && -n "$REL" ]] || { echo "No iMonitor Platform release found." >&2; exit 3; }
TAG="$(jq -r '.tag_name' <<<"$REL")"
VERSION="${TAG#imonitor-platform-v}"
CURRENT="$(cat "$STATE_ROOT/current-version" 2>/dev/null || true)"

if [[ "$CURRENT" == "$VERSION" && $FORCE -eq 0 ]]; then
  log "Already on latest release $VERSION"
  exit 0
fi

SRC_NAME="iMonitor-Platform-source-v${VERSION}.tar.gz"
IMG_NAME="iMonitor-Platform-docker-images-v${VERSION}.tar.gz"
SUM_NAME="SHA256SUMS-v${VERSION}.txt"
SRC_URL="$(asset_url "$REL" "$SRC_NAME")"
IMG_URL="$(asset_url "$REL" "$IMG_NAME")"
SUM_URL="$(asset_url "$REL" "$SUM_NAME")"
[[ -n "$SRC_URL" && -n "$IMG_URL" && -n "$SUM_URL" ]] || { echo "Release assets are incomplete." >&2; exit 4; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
log "Downloading release $VERSION"
curl -fL --retry 5 --retry-delay 3 "$SRC_URL" -o "$TMP/$SRC_NAME"
curl -fL --retry 5 --retry-delay 3 "$IMG_URL" -o "$TMP/$IMG_NAME"
curl -fL --retry 5 --retry-delay 3 "$SUM_URL" -o "$TMP/$SUM_NAME"
(cd "$TMP" && sha256sum -c "$SUM_NAME")

RELEASE_DIR="$PRODUCT_ROOT/releases/$VERSION"
rm -rf "$RELEASE_DIR"; mkdir -p "$RELEASE_DIR"
tar -xzf "$TMP/$SRC_NAME" -C "$RELEASE_DIR" --strip-components=1

if [[ ! -f "$CONFIG_ROOT/imonitor.env" ]]; then
  DB_PASS="$(openssl rand -hex 18)"
  ROOT_PASS="$(openssl rand -hex 18)"
  SECRET="$(openssl rand -hex 32)"
  cat > "$CONFIG_ROOT/imonitor.env" <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
MYSQL_ROOT_PASSWORD=${ROOT_PASS}
MYSQL_DATABASE=factory_tracking
MYSQL_USER=factory_user
MYSQL_PASSWORD=${DB_PASS}
SECRET_KEY=${SECRET}
APP_PORT=8000
FRONTEND_PORT=3000
NGINX_PORT=80
NGINX_SSL_PORT=443
FTP_PORT=21
FTP_PASSIVE_START=30000
FTP_PASSIVE_END=30010
FTP_SHARED_GID=1000
EOF
  chmod 600 "$CONFIG_ROOT/imonitor.env"
fi
cp "$CONFIG_ROOT/imonitor.env" "$RELEASE_DIR/.env"

log "Loading prebuilt Docker images"
gzip -dc "$TMP/$IMG_NAME" | docker load

ln -sfn "$RELEASE_DIR" "$PRODUCT_ROOT/current"
cd "$PRODUCT_ROOT/current"
export COMPOSE_PROJECT_NAME
log "Starting iMonitor Platform"
compose up -d --no-build

if need ufw && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw allow 3000/tcp || true
  ufw allow 8000/tcp || true
  ufw allow 21/tcp || true
  ufw allow 30000:30010/tcp || true
fi

cat > /etc/systemd/system/imonitor-platform.service <<'EOF'
[Unit]
Description=iMonitor Platform Docker Compose stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/imonitor-platform/current
Environment=COMPOSE_PROJECT_NAME=imonitor
ExecStart=/bin/sh -c 'docker compose up -d --no-build || docker-compose up -d --no-build'
ExecStop=/bin/sh -c 'docker compose stop || docker-compose stop'
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable imonitor-platform.service >/dev/null 2>&1 || true

echo "$VERSION" > "$STATE_ROOT/current-version"
echo "$INSTALLER_VERSION" > "$STATE_ROOT/installer-version"

if [[ $UPDATE_ONLY -eq 0 ]]; then
  UPDATER_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/main/scripts/Update-iMonitorPlatform-v1.0.0.sh?cachebust=$(date +%s)"
  curl -fsSL "$UPDATER_URL" -o /usr/local/sbin/imonitor-platform-update
  chmod 755 /usr/local/sbin/imonitor-platform-update
  cat > /etc/systemd/system/imonitor-platform-update.service <<'EOF'
[Unit]
Description=Check and install latest iMonitor Platform release
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/imonitor-platform-update
EOF
  cat > /etc/systemd/system/imonitor-platform-update.timer <<'EOF'
[Unit]
Description=Check iMonitor Platform updates every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now imonitor-platform-update.timer >/dev/null 2>&1 || true
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "Installed iMonitor Platform $VERSION"
echo "Web: http://${IP:-SERVER-IP}:3000"
echo "Gateway: http://${IP:-SERVER-IP}:80"
echo "API: http://${IP:-SERVER-IP}:8000"
echo "FTP: ${IP:-SERVER-IP}:21 (passive 30000-30010)"
compose ps
