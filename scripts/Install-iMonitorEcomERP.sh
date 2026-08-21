#!/usr/bin/env bash
set -euo pipefail

CHANNEL="test"
if [[ "${1:-}" == "--channel" ]]; then
  CHANNEL="${2:-test}"
fi

APP="imonitor-ecom-erp-${CHANNEL}"
BASE="/opt/${APP}"
REPO="alimirzae/iMonitor-Erp-Releases"

if ! command -v docker >/dev/null 2>&1; then
  apt update
  apt install -y docker.io docker-compose-plugin curl jq
  systemctl enable --now docker
fi

mkdir -p "$BASE"
cd "$BASE"

RELEASE_API="https://api.github.com/repos/${REPO}/releases"

LATEST=$(curl -fsSL "$RELEASE_API" | jq -r --arg c "$CHANNEL" '.[] | select(.prerelease == ($c == "test")) | .tag_name' | head -n1)

if [[ -z "$LATEST" || "$LATEST" == "null" ]]; then
  echo "No release found for channel: $CHANNEL"
  exit 1
fi

INSTALLED=""
[[ -f version ]] && INSTALLED=$(cat version)

if [[ "$INSTALLED" == "$LATEST" ]]; then
  echo "Already running $LATEST"
  exit 0
fi

echo "Updating $APP: $INSTALLED -> $LATEST"

OLD_IMAGE=$(docker compose images -q 2>/dev/null || true)

curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/server/ecom/compose.yml" -o compose.yml

IMAGE="ghcr.io/alimirzae/imonitor-ecom-erp:${LATEST}"
export IMAGE

printf "%s" "$LATEST" > version

docker compose pull
docker compose up -d

sleep 10

if ! docker compose ps | grep -q "Up"; then
  echo "Deployment failed. Rolling back."
  docker compose down || true
  git checkout -- version || true
  exit 1
fi

echo "Installed $LATEST"

cat >/etc/systemd/system/${APP}-update.service <<EOF
[Unit]
Description=iMonitor Ecom ERP update

[Service]
Type=oneshot
ExecStart=/usr/local/bin/${APP}-update
EOF

cat >/usr/local/bin/${APP}-update <<EOF
#!/bin/bash
bash /opt/${APP}/installer.sh --channel ${CHANNEL}
EOF

chmod +x /usr/local/bin/${APP}-update

cat >/etc/systemd/system/${APP}-update.timer <<EOF
[Unit]
Description=iMonitor Ecom ERP automatic update

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF

cp "$0" "$BASE/installer.sh"
systemctl daemon-reload
systemctl enable --now ${APP}-update.timer
