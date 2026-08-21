#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:-test}"
APP="imonitor-ecom-erp-${CHANNEL}"
BASE="/opt/${APP}"
REPO="alimirzae/iMonitor-Erp-Releases"

apt_install(){
  apt update
  apt install -y curl jq docker.io docker-compose-plugin
  systemctl enable --now docker
}

command -v docker >/dev/null || apt_install
mkdir -p "$BASE"
cd "$BASE"

URL="https://raw.githubusercontent.com/${REPO}/main/server/ecom/channels/${CHANNEL}.json"
curl -fsSL "$URL" -o release.json

IMAGE=$(jq -r '.image' release.json)
VERSION=$(jq -r '.version' release.json)

echo "Installing ${APP} ${VERSION}"

curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/server/ecom/compose.yml" -o compose.yml
export IMAGE

docker compose pull
docker compose up -d

cat >/usr/local/bin/${APP}-update <<EOF
#!/bin/bash
cd ${BASE}
curl -fsSL ${URL} -o release.json
export IMAGE=\$(jq -r '.image' release.json)
docker compose pull
docker compose up -d
EOF
chmod +x /usr/local/bin/${APP}-update

cat >/etc/systemd/system/${APP}.timer <<EOF
[Unit]
Description=iMonitor Ecom ERP automatic update
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/${APP}.service <<EOF
[Unit]
Description=iMonitor Ecom ERP update
[Service]
Type=oneshot
ExecStart=/usr/local/bin/${APP}-update
EOF

systemctl daemon-reload
systemctl enable --now ${APP}.timer

echo "${APP} installed"