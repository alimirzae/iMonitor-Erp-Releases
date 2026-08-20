#!/usr/bin/env bash
set -Eeuo pipefail

BASE="https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main"
CHANNEL="test"
ROOT="/opt/imonitor-erp"
DASHBOARD_PORT=10000
UPDATE_MINUTES=""
WINDOW_START="02:00"
WINDOW_END="05:00"
TZ_NAME="Asia/Tehran"
FORCE=0
INSTALL_DASHBOARD=1

usage(){ cat <<'EOF'
iMonitor ERP unified installer/updater

Usage:
  Install-iMonitorERP.sh [options]

Options:
  --channel development|test|stable   Release channel (default: test)
  --root PATH                         Installation root (default: /opt/imonitor-erp)
  --dashboard-port PORT               Developer dashboard port (default: 10000)
  --update-minutes N                  Poll interval for development/test
  --window-start HH:MM                Stable update window start (default: 02:00 Tehran)
  --window-end HH:MM                  Stable update window end (default: 05:00 Tehran)
  --timezone TZ                       Stable update timezone (default: Asia/Tehran)
  --force-update                      Apply latest release immediately, ignoring stable window
  --no-dashboard                      Do not install/start dashboard
  -h|--help                           Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="$2"; shift 2;;
    --root) ROOT="$2"; shift 2;;
    --dashboard-port) DASHBOARD_PORT="$2"; shift 2;;
    --update-minutes) UPDATE_MINUTES="$2"; shift 2;;
    --window-start) WINDOW_START="$2"; shift 2;;
    --window-end) WINDOW_END="$2"; shift 2;;
    --timezone) TZ_NAME="$2"; shift 2;;
    --force-update) FORCE=1; shift;;
    --no-dashboard) INSTALL_DASHBOARD=0; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

case "$CHANNEL" in development|test|stable) ;; *) echo "Invalid channel: $CHANNEL" >&2; exit 2;; esac
if [[ -z "$UPDATE_MINUTES" ]]; then
  case "$CHANNEL" in development) UPDATE_MINUTES=1;; test) UPDATE_MINUTES=5;; stable) UPDATE_MINUTES=15;; esac
fi
[[ "$EUID" -eq 0 ]] || { echo "Run with sudo/root." >&2; exit 1; }
command -v curl >/dev/null || { apt-get update && apt-get install -y curl ca-certificates; }

# Backward-compatible source channel mapping.
SOURCE_CHANNEL="$CHANNEL"
[[ "$CHANNEL" == "stable" ]] && SOURCE_CHANNEL="main"

in_stable_window(){
  [[ "$CHANNEL" != "stable" || "$FORCE" -eq 1 ]] && return 0
  local now
  now="$(TZ="$TZ_NAME" date +%H:%M)"
  [[ "$now" > "$WINDOW_START" || "$now" == "$WINDOW_START" ]] && [[ "$now" < "$WINDOW_END" || "$now" == "$WINDOW_END" ]]
}

if ! in_stable_window; then
  echo "Stable update available/check requested, but current time is outside ${WINDOW_START}-${WINDOW_END} ${TZ_NAME}."
  echo "Use --force-update to override."
  exit 0
fi

SERVER_SCRIPT="/tmp/Install-iMonitorERP-Server.sh"
curl -fsSL "$BASE/scripts/Install-iMonitorERP-Server.sh" -o "$SERVER_SCRIPT"
chmod +x "$SERVER_SCRIPT"

ARGS=(--channel "$SOURCE_CHANNEL" --root "$ROOT" --update-minutes "$UPDATE_MINUTES")
"$SERVER_SCRIPT" "${ARGS[@]}"

# Save local updater policy for the dashboard and timer service.
POLICY_ROOT="${ROOT%/}/policy"
mkdir -p "$POLICY_ROOT"
cat > "$POLICY_ROOT/update.env" <<EOF
IMONITOR_RELEASE_CHANNEL=$CHANNEL
IMONITOR_SOURCE_CHANNEL=$SOURCE_CHANNEL
IMONITOR_UPDATE_MINUTES=$UPDATE_MINUTES
IMONITOR_UPDATE_WINDOW_START=$WINDOW_START
IMONITOR_UPDATE_WINDOW_END=$WINDOW_END
IMONITOR_UPDATE_TIMEZONE=$TZ_NAME
IMONITOR_DASHBOARD_PORT=$DASHBOARD_PORT
EOF
chmod 644 "$POLICY_ROOT/update.env"

if [[ "$INSTALL_DASHBOARD" -eq 1 ]]; then
  install -d /opt/imonitor-dev-dashboard
  curl -fsSL "$BASE/scripts/imonitor-dev-dashboard.py" -o /opt/imonitor-dev-dashboard/dashboard.py
  chmod 755 /opt/imonitor-dev-dashboard/dashboard.py
  cat > /etc/systemd/system/imonitor-dev-dashboard.service <<EOF
[Unit]
Description=iMonitor ERP Developer Dashboard
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
Environment=IMONITOR_MONITOR_HOST=0.0.0.0
Environment=IMONITOR_MONITOR_PORT=$DASHBOARD_PORT
Environment=IMONITOR_RELEASE_POLICY=$POLICY_ROOT/update.env
ExecStart=/usr/bin/python3 /opt/imonitor-dev-dashboard/dashboard.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now imonitor-dev-dashboard.service
fi

echo "[OK] iMonitor ERP channel=$CHANNEL installed/updated."
echo "Dashboard: http://localhost:${DASHBOARD_PORT}"
echo "Test API : http://localhost:8081"
echo "Stable   : http://localhost:8080"
