#!/usr/bin/env bash
set -euo pipefail
REPO="alimirzae/iMonitor-Erp-Releases"
STATE="/var/lib/imonitor-platform"
MANIFEST_URL="https://raw.githubusercontent.com/${REPO}/main/manifests/imonitor-platform-release.json?cachebust=$(date +%s)"
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
mkdir -p "$STATE/installers"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 5 "$MANIFEST_URL" -o "$TMP"
VER="$(jq -r '.installer_version' "$TMP")"
PATHNAME="$(jq -r '.installer_path' "$TMP")"
[[ -n "$VER" && "$VER" != "null" && -n "$PATHNAME" && "$PATHNAME" != "null" ]] || { echo 'Invalid update manifest'; exit 2; }
INSTALLER="$STATE/installers/Install-iMonitorPlatform-v${VER}.sh"
curl -fsSL --retry 5 "https://raw.githubusercontent.com/${REPO}/main/${PATHNAME}?cachebust=$(date +%s)" -o "$INSTALLER.tmp"
mv "$INSTALLER.tmp" "$INSTALLER"
chmod 700 "$INSTALLER"
exec "$INSTALLER" --update-only
