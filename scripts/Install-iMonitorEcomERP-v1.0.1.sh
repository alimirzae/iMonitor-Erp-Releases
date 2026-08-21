#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.1"
CHANNEL="test"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ "$CHANNEL" == "stable" || "$CHANNEL" == "master" ]]; then
  CHANNEL="master"
  PORT=80
else
  CHANNEL="test"
  PORT=8080
fi

APP="imonitor-ecom-erp-${CHANNEL}"
BASE="/opt/${APP}"
REPO="alimirzae/iMonitor-Erp-Releases"
SERVICE="${APP}.service"

install_base_packages(){
  apt-get update
  apt-get install -y curl jq unzip wget ca-certificates gnupg tar
}

install_dotnet(){
  if command -v dotnet >/dev/null 2>&1 && dotnet --list-runtimes | grep -q "Microsoft.AspNetCore.App 8."; then
    return
  fi

  echo "Installing .NET 8 runtime"
  mkdir -p /usr/share/dotnet
  wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh
  chmod +x /tmp/dotnet-install.sh
  /tmp/dotnet-install.sh --channel 8.0 --runtime aspnetcore --install-dir /usr/share/dotnet

  ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
}

install_base_packages
install_dotnet

mkdir -p "$BASE/releases"
cd "$BASE"

API="https://api.github.com/repos/${REPO}/releases"

TAG=$(curl -fsSL "$API" | jq -r --arg c "$CHANNEL" '.[] | select(.tag_name|ascii_downcase|contains($c)) | .tag_name' | head -n1)

if [[ -z "$TAG" || "$TAG" == "null" ]]; then
 echo "No release found for channel $CHANNEL"
 exit 1
fi

CURRENT=""
[[ -f version ]] && CURRENT=$(cat version)

if [[ "$CURRENT" == "$TAG" ]]; then
 echo "Already installed $TAG"
 exit 0
fi

ASSET=$(curl -fsSL "$API/tags/$TAG" | jq -r '.assets[] | select(.name|endswith(".zip")) | .browser_download_url' | head -n1)

if [[ -z "$ASSET" || "$ASSET" == "null" ]]; then
 echo "No zip asset found"
 exit 1
fi

rm -rf new
mkdir new
curl -fsSL "$ASSET" -o release.zip
unzip -oq release.zip -d new

if [[ -d current ]]; then
 mv current backup-${CURRENT:-unknown} || true
fi
mv new current
echo "$TAG" > version

cat >/etc/systemd/system/$SERVICE <<EOF
[Unit]
Description=iMonitor Ecom ERP ${CHANNEL}
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

sleep 10
systemctl is-active --quiet $SERVICE || {
 echo "Service failed"
 exit 1
}

cp "$0" "$BASE/installer.sh" 2>/dev/null || true

echo "Installed $APP version $TAG on port $PORT"
