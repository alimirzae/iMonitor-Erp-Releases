#!/usr/bin/env bash
set -euo pipefail
CHANNEL="test"
REPO="alimirzae/iMonitor-Erp-Releases"
PRODUCT="imonitor-ecom-erp"
PORT=8080
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$CHANNEL" == "test" || "$CHANNEL" == "master" ]] || { echo "channel must be test or master" >&2; exit 2; }
[[ "$CHANNEL" == "master" ]] && PORT=80
BASE="/opt/${PRODUCT}-${CHANNEL}"
SERVICE="${PRODUCT}-${CHANNEL}"
API="https://api.github.com/repos/${REPO}/releases"
ASSET="iMonitor-EcomERP-linux-x64.tar.gz"
INSTALLER_PATH="/usr/local/lib/${PRODUCT}/installer.sh"
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || fail "Run with sudo/root."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl jq ca-certificates tar
if ! command -v dotnet >/dev/null 2>&1 || ! dotnet --list-runtimes 2>/dev/null | grep -q '^Microsoft.AspNetCore.App 8\.'; then
  log "Installing ASP.NET Core Runtime 8"
  mkdir -p /opt/dotnet
  curl -fsSL --retry 5 https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --channel 8.0 --runtime aspnetcore --install-dir /opt/dotnet --no-path
  ln -sfn /opt/dotnet/dotnet /usr/local/bin/dotnet
fi
mkdir -p "$BASE" "$(dirname "$INSTALLER_PATH")"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" && "$SCRIPT_SOURCE" != "$INSTALLER_PATH" ]]; then
  install -m 0755 "$SCRIPT_SOURCE" "$INSTALLER_PATH"
elif [[ "$SCRIPT_SOURCE" != "$INSTALLER_PATH" ]]; then
  curl -fsSL --retry 5 \
    "https://raw.githubusercontent.com/${REPO}/main/scripts/Install-iMonitorEcomERP-v1.0.5.sh" \
    -o "$INSTALLER_PATH"
  chmod 0755 "$INSTALLER_PATH"
fi
release_json="$(curl -fsSL --retry 5 "$API")"
tag="$(jq -r --arg prefix "imonitor-ecomerp-${CHANNEL}-v" '[.[] | select(.draft == false and .prerelease == false) | select(.tag_name | startswith($prefix))] | first | .tag_name // empty' <<<"$release_json")"
[[ -n "$tag" ]] || fail "No release found for channel $CHANNEL"
current="$(cat "$BASE/version" 2>/dev/null || true)"
if [[ "$current" != "$tag" ]]; then
  detail="$(curl -fsSL --retry 5 "$API/tags/$tag")"
  asset_url="$(jq -r --arg name "$ASSET" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$detail" | head -n1)"
  checksum_url="$(jq -r --arg name "$ASSET.sha256" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$detail" | head -n1)"
  [[ -n "$asset_url" && -n "$checksum_url" ]] || fail "Linux asset or checksum missing in $tag"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  curl -fL --retry 5 --retry-delay 5 --progress-bar "$asset_url" -o "$work/$ASSET"
  curl -fsSL --retry 5 "$checksum_url" -o "$work/$ASSET.sha256"
  (cd "$work" && sha256sum -c "$ASSET.sha256")
  mkdir "$work/new"
  tar -xzf "$work/$ASSET" -C "$work/new"
  [[ -f "$work/new/Ecomm.dll" ]] || fail "Release does not contain Ecomm.dll"
  rm -rf "$BASE/previous"
  [[ -d "$BASE/current" ]] && mv "$BASE/current" "$BASE/previous"
  mv "$work/new" "$BASE/current"
  echo "$tag" > "$BASE/version"
  log "Installed $tag"
else
  log "Already current: $tag"
fi
cat >"/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=iMonitor Ecom ERP ($CHANNEL)
After=network-online.target
Wants=network-online.target
[Service]
WorkingDirectory=$BASE/current
ExecStart=/usr/local/bin/dotnet $BASE/current/Ecomm.dll --urls http://0.0.0.0:$PORT
Restart=always
RestartSec=5
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_ROOT=/opt/dotnet
[Install]
WantedBy=multi-user.target
EOF
cat >"/etc/systemd/system/${SERVICE}-update.service" <<EOF
[Unit]
Description=Update iMonitor Ecom ERP ($CHANNEL)
[Service]
Type=oneshot
ExecStart=$INSTALLER_PATH --channel $CHANNEL
EOF
cat >"/etc/systemd/system/${SERVICE}-update.timer" <<EOF
[Unit]
Description=Check iMonitor Ecom ERP updates ($CHANNEL)
[Timer]
OnBootSec=10min
OnUnitActiveSec=30min
RandomizedDelaySec=3min
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now "$SERVICE"
systemctl enable --now "${SERVICE}-update.timer"
systemctl restart "$SERVICE"
log "Installer 1.0.5 completed; channel=$CHANNEL port=$PORT tag=$tag"
