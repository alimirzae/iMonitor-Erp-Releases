#!/usr/bin/env bash
set -Eeuo pipefail

ENVIRONMENT=""
DOMAIN=""
BACKEND_PORT=""
EMAIL=""
MODE="auto"
DRY_RUN=0

usage(){ cat <<'EOF'
iMonitor ERP domain / reverse-proxy / TLS configurator

Usage:
  sudo Configure-iMonitorERP-Domain.sh --environment test|stable --domain host.example.com [options]

Options:
  --environment test|stable   Target ERP environment
  --domain FQDN               Public DNS name
  --backend-port PORT         Override backend port (test 8081, stable 8080)
  --email EMAIL               ACME contact email (optional)
  --mode auto|caddy|iis       Proxy mode; Linux/WSL uses Caddy, Windows native uses IIS helper
  --dry-run                   Validate only; do not change proxy config
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment) ENVIRONMENT="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --backend-port) BACKEND_PORT="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

[[ "$ENVIRONMENT" == test || "$ENVIRONMENT" == stable ]] || { echo 'environment must be test or stable' >&2; exit 2; }
[[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]] || { echo 'invalid domain' >&2; exit 2; }
if [[ -z "$BACKEND_PORT" ]]; then [[ "$ENVIRONMENT" == test ]] && BACKEND_PORT=8081 || BACKEND_PORT=8080; fi
[[ "$EUID" -eq 0 ]] || { echo 'run with sudo/root' >&2; exit 1; }

IP_LOCAL="$(hostname -I 2>/dev/null | awk '{print $1}')"
DNS4="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
echo "Domain      : $DOMAIN"
echo "Environment : $ENVIRONMENT"
echo "Backend     : 127.0.0.1:$BACKEND_PORT"
echo "Local IP    : ${IP_LOCAL:-unknown}"
echo "DNS A       : ${DNS4:-unresolved}"

curl -fsS --max-time 3 "http://127.0.0.1:${BACKEND_PORT}/health" >/tmp/imonitor-domain-health.json || { echo 'Backend health check failed.' >&2; exit 1; }
echo '[OK] backend health'

if [[ "$DRY_RUN" -eq 1 ]]; then exit 0; fi

if [[ "$MODE" == iis ]]; then
  echo 'IIS mode must be run using Configure-iMonitorERP-IIS.ps1 on Windows.' >&2
  exit 2
fi

if ! command -v caddy >/dev/null 2>&1; then
  apt-get update
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
fi

mkdir -p /etc/caddy/imonitor.d
CONF="/etc/caddy/imonitor.d/${ENVIRONMENT}.caddy"
cat > "$CONF" <<EOF
$DOMAIN {
    reverse_proxy 127.0.0.1:$BACKEND_PORT
}
EOF

MAIN=/etc/caddy/Caddyfile
if ! grep -q 'import /etc/caddy/imonitor.d/\*.caddy' "$MAIN" 2>/dev/null; then
  printf '\nimport /etc/caddy/imonitor.d/*.caddy\n' >> "$MAIN"
fi

caddy validate --config "$MAIN"
systemctl enable --now caddy
systemctl reload caddy
sleep 2

echo '[OK] reverse proxy configured.'
echo 'Caddy will request and renew public TLS automatically when DNS points to this host and ports 80/443 are reachable.'
curl -kIsS --max-time 8 "https://${DOMAIN}/health" | head -1 || true
