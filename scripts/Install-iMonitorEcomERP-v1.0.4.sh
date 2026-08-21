#!/usr/bin/env bash
set -euo pipefail

CHANNEL="test"
APP="imonitor-ecom-erp"
BASE="/opt/${APP}-${CHANNEL}"
REPO="alimirzae/iMonitor-Erp-Releases"
PORT=8080

while [[ $# -gt 0 ]]; do
 case "$1" in
  --channel) CHANNEL="$2"; shift 2;;
  *) shift;;
 esac
done

[[ "$CHANNEL" == "master" ]] && PORT=80

log(){ echo "[$(date '+%F %T')] $*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }

install -m 755 /dev/null /tmp/empty >/dev/null 2>&1 || true
apt-get update
apt-get install -y curl jq unzip ca-certificates

mkdir -p "$BASE"

API="https://api.github.com/repos/${REPO}/releases"

find_release(){
 curl -fsSL "$API" | jq -r --arg c "$CHANNEL" '.[] | select(.tag_name|ascii_downcase|startswith("imonitor-ecomerp-") and contains($c)) | .tag_name' | head -n1
}

install_release(){
 TAG=$(find_release)
 [[ -n "$TAG" ]] || fail "No Ecomm ERP release found"
 CURRENT="$(cat "$BASE/version" 2>/dev/null || true)"
 [[ "$CURRENT" == "$TAG" ]] && { log "Already latest $TAG"; return; }

 URL=$(curl -fsSL "$API/tags/$TAG" | jq -r '.assets[] | select(.name|endswith(".zip")) | .browser_download_url' | head -n1)
 [[ -n "$URL" ]] || fail "No zip asset"

 log "Downloading $TAG"
 curl -fL --retry 5 --retry-delay 10 --progress-bar "$URL" -o "$BASE/release.zip"
 unzip -oq "$BASE/release.zip" -d "$BASE/new"

 rm -rf "$BASE/backup"
 [[ -d "$BASE/current" ]] && mv "$BASE/current" "$BASE/backup"
 mv "$BASE/new" "$BASE/current"
 echo "$TAG" > "$BASE/version"

 systemctl restart "$APP-$CHANNEL.service" || true
 log "Installed $TAG"
}

install_release

cat >/etc/systemd/system/${APP}-${CHANNEL}.service <<EOF
[Unit]
Description=iMonitor Ecom ERP
After=network.target

[Service]
WorkingDirectory=$BASE/current
ExecStart=/usr/bin/dotnet Ecomm.dll --urls http://0.0.0.0:$PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >/usr/local/bin/${APP}-${CHANNEL}-update <<EOF
#!/bin/bash
$0 --channel $CHANNEL
EOF
chmod +x /usr/local/bin/${APP}-${CHANNEL}-update

cat >/etc/systemd/system/${APP}-${CHANNEL}-update.service <<EOF
[Service]
Type=oneshot
ExecStart=/usr/local/bin/${APP}-${CHANNEL}-update
EOF

cat >/etc/systemd/system/${APP}-${CHANNEL}-update.timer <<EOF
[Timer]
OnBootSec=10min
OnUnitActiveSec=30min
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ${APP}-${CHANNEL}.service
systemctl enable --now ${APP}-${CHANNEL}-update.timer

log "Completed. Auto update enabled."
