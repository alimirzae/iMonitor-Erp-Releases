#!/usr/bin/env bash
set -euo pipefail

CHANNEL="test"
if [[ "${1:-}" == "--channel" ]]; then
  CHANNEL="${2:-test}"
fi

if [[ "$CHANNEL" == "master" ]]; then
  PORT=80
else
  PORT=8080
fi

APP="imonitor-ecom-erp-${CHANNEL}"
BASE="/opt/${APP}"
REPO="alimirzae/iMonitor-Erp-Releases"
SERVICE="${APP}.service"

apt update
apt install -y curl jq aspnetcore-runtime-8.0 unzip

mkdir -p "$BASE/releases"
cd "$BASE"

API="https://api.github.com/repos/${REPO}/releases"

TAG=$(curl -fsSL "$API" | jq -r --arg c "$CHANNEL" '.[] | select(.name|ascii_downcase|contains($c)) | .tag_name' | head -n1)

if [[ -z "$TAG" || "$TAG" == "null" ]]; then
  echo "No Ecom ERP release found for channel $CHANNEL"
  exit 1
fi

CURRENT=""
[[ -f version ]] && CURRENT=$(cat version)

if [[ "$CURRENT" == "$TAG" ]]; then
  echo "Already running $TAG"
  exit 0
fi

echo "Installing $APP $TAG"

URL=$(curl -fsSL "$API/tags/$TAG" | jq -r '.assets[0].browser_download_url')

if [[ -z "$URL" || "$URL" == "null" ]]; then
  echo "Release asset not found"
  exit 1
fi

BACKUP="$BASE/backup-$CURRENT"
if [[ -d current ]]; then
  cp -a current "$BACKUP" || true
fi

rm -rf new
mkdir new
curl -fsSL "$URL" -o release.zip
unzip -oq release.zip -d new

mv current old 2>/dev/null || true
mv new current

echo "$TAG" > version

cat >/etc/systemd/system/$SERVICE <<EOF
[Unit]
Description=iMonitor Ecom ERP $CHANNEL
After=network.target

[Service]
WorkingDirectory=$BASE/current
ExecStart=/usr/bin/dotnet Ecomm.dll --urls http://0.0.0.0:$PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE
systemctl restart $SERVICE

sleep 15

if ! systemctl is-active --quiet $SERVICE; then
  echo "Health check failed. Rolling back."
  rm -rf current
  mv old current || true
  echo "$CURRENT" > version
  systemctl restart $SERVICE || true
  exit 1
fi

cat >/usr/local/bin/${APP}-update <<EOF
#!/bin/bash
$BASE/installer.sh --channel $CHANNEL
EOF
chmod +x /usr/local/bin/${APP}-update

cp "$0" "$BASE/installer.sh"

cat >/etc/systemd/system/${APP}-update.timer <<EOF
[Unit]
Description=iMonitor Ecom ERP automatic update

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/${APP}-update.service <<EOF
[Unit]
Description=iMonitor Ecom ERP updater

[Service]
Type=oneshot
ExecStart=/usr/local/bin/${APP}-update
EOF

systemctl daemon-reload
systemctl enable --now ${APP}-update.timer

echo "$APP installed on port $PORT"
