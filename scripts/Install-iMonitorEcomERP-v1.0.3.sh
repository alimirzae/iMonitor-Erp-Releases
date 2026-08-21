#!/usr/bin/env bash
set -euo pipefail

CHANNEL="test"
APP="imonitor-ecom-erp"
BASE="/opt/${APP}-${CHANNEL}"
REPO="alimirzae/iMonitor-Erp-Releases"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="$2"; shift 2;;
    *) shift;;
  esac
done

log(){ echo "[$(date '+%F %T')] $*"; }

install -y curl jq unzip ca-certificates >/dev/null

mkdir -p "$BASE"

install_release(){
  API="https://api.github.com/repos/${REPO}/releases"
  TAG=$(curl -fsSL "$API" | jq -r --arg c "$CHANNEL" '.[] | select(.tag_name|ascii_downcase|startswith("imonitor-ecomerp-") and contains($c)) | .tag_name' | head -n1)

  [[ -n "$TAG" && "$TAG" != null ]] || { log "No Ecomm ERP release found"; return 1; }

  CURRENT=""
  [[ -f "$BASE/version" ]] && CURRENT=$(cat "$BASE/version")

  [[ "$CURRENT" != "$TAG" ]] || { log "Already latest: $TAG"; return 0; }

  URL=$(curl -fsSL "$API/tags/$TAG" | jq -r '.assets[] | select(.name|endswith(".zip")) | .browser_download_url' | head -n1)

  rm -rf "$BASE/new"
  mkdir -p "$BASE/new"

  log "Downloading $TAG"
  curl -fL --retry 5 --progress-bar "$URL" -o "$BASE/release.zip"

  unzip -oq "$BASE/release.zip" -d "$BASE/new"

  rm -rf "$BASE/current"
  mv "$BASE/new" "$BASE/current"
  echo "$TAG" > "$BASE/version"

  systemctl restart "$APP-$CHANNEL.service" || true
  log "Updated to $TAG"
}

install_release

cat >/usr/local/bin/${APP}-${CHANNEL}-update <<EOF
#!/bin/bash
$0 --channel $CHANNEL
EOF
chmod +x /usr/local/bin/${APP}-${CHANNEL}-update

cat >/etc/systemd/system/${APP}-${CHANNEL}-update.timer <<EOF
[Unit]
Description=iMonitor Ecom ERP update checker

[Timer]
OnBootSec=10min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/${APP}-${CHANNEL}-update.service <<EOF
[Service]
Type=oneshot
ExecStart=/usr/local/bin/${APP}-${CHANNEL}-update
EOF

systemctl daemon-reload
systemctl enable --now ${APP}-${CHANNEL}-update.timer

log "Installer completed. Automatic update checker enabled."
