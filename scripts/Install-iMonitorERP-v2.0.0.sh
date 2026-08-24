#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2.0.0"
REPO="alimirzae/iMonitor-Erp-Releases"
ROOT="/opt/imonitor-erp"
CONFIG_ROOT="/etc/imonitor-erp"
STATE_ROOT="/var/lib/imonitor-erp"
CREDENTIALS="$CONFIG_ROOT/credentials.env"
COMPOSE_FILE="$ROOT/docker-compose.yml"
CHANNEL="both"
UPDATE_ONLY=0
FORCE=0
TEST_PORT=8080
PROD_PORT=8081
PHPMYADMIN_PORT=8082

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-both}"; shift 2 ;;
    --update-only) UPDATE_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    --test-port) TEST_PORT="$2"; shift 2 ;;
    --production-port|--prod-port) PROD_PORT="$2"; shift 2 ;;
    --phpmyadmin-port) PHPMYADMIN_PORT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$CHANNEL" =~ ^(both|test|master|production)$ ]] || { echo "channel must be both, test, master or production" >&2; exit 2; }
[[ "$CHANNEL" == "production" ]] && CHANNEL="master"
[[ $EUID -eq 0 ]] || { echo "Run with sudo/root." >&2; exit 1; }

log(){ printf '\n[iMonitor ERP] %s\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1; }
random_secret(){ openssl rand -base64 36 | tr -d '\n/=+' | head -c 32; }

install_dependencies(){
  local missing=()
  for cmd in curl jq tar sha256sum openssl; do need "$cmd" || missing+=("$cmd"); done
  if (( ${#missing[@]} )); then
    need apt-get || fail "Debian/Ubuntu is required for automatic dependency installation."
    apt-get -o Acquire::ForceIPv4=true update || log "APT refresh failed; trying cached indexes"
    apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends curl jq tar ca-certificates coreutils openssl \
      || fail "Cannot install required tools. Check server network routing."
  fi
  if ! need docker; then
    need apt-get || fail "Docker is required."
    apt-get -o Acquire::ForceIPv4=true update || true
    apt-get -o Acquire::ForceIPv4=true install -y docker.io docker-compose-v2 \
      || fail "Docker installation failed."
  fi
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required."
  systemctl enable --now docker >/dev/null 2>&1 || true
}

create_credentials(){
  mkdir -p "$CONFIG_ROOT" "$STATE_ROOT" "$ROOT/releases/test" "$ROOT/releases/master" "$ROOT/config"
  chmod 700 "$CONFIG_ROOT"
  if [[ ! -f "$CREDENTIALS" ]]; then
    umask 077
    cat > "$CREDENTIALS" <<EOF
MYSQL_ROOT_PASSWORD=$(random_secret)
MYSQL_TEST_DATABASE=imonitor_erp_test
MYSQL_TEST_USER=imonitor_test
MYSQL_TEST_PASSWORD=$(random_secret)
MYSQL_PROD_DATABASE=imonitor_erp_production
MYSQL_PROD_USER=imonitor_production
MYSQL_PROD_PASSWORD=$(random_secret)
TEST_PORT=$TEST_PORT
PROD_PORT=$PROD_PORT
PHPMYADMIN_PORT=$PHPMYADMIN_PORT
EOF
  fi
  chmod 600 "$CREDENTIALS"
  # Preserve initially selected ports but allow explicit installer arguments to update them.
  sed -i -E "s/^TEST_PORT=.*/TEST_PORT=$TEST_PORT/;s/^PROD_PORT=.*/PROD_PORT=$PROD_PORT/;s/^PHPMYADMIN_PORT=.*/PHPMYADMIN_PORT=$PHPMYADMIN_PORT/" "$CREDENTIALS"
  set -a; source "$CREDENTIALS"; set +a
}

write_mysql_init(){
  mkdir -p "$ROOT/mysql-init"
  cat > "$ROOT/mysql-init/01-databases.sql" <<EOF
CREATE DATABASE IF NOT EXISTS \`$MYSQL_TEST_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`$MYSQL_PROD_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$MYSQL_TEST_USER'@'%' IDENTIFIED BY '$MYSQL_TEST_PASSWORD';
CREATE USER IF NOT EXISTS '$MYSQL_PROD_USER'@'%' IDENTIFIED BY '$MYSQL_PROD_PASSWORD';
ALTER USER '$MYSQL_TEST_USER'@'%' IDENTIFIED BY '$MYSQL_TEST_PASSWORD';
ALTER USER '$MYSQL_PROD_USER'@'%' IDENTIFIED BY '$MYSQL_PROD_PASSWORD';
GRANT ALL PRIVILEGES ON \`$MYSQL_TEST_DATABASE\`.* TO '$MYSQL_TEST_USER'@'%';
GRANT ALL PRIVILEGES ON \`$MYSQL_PROD_DATABASE\`.* TO '$MYSQL_PROD_USER'@'%';
FLUSH PRIVILEGES;
EOF
  chmod 600 "$ROOT/mysql-init/01-databases.sql"
}

release_json(){
  local channel="$1" prefix
  prefix="imonitor-ecomerp-${channel}-v"
  curl -fsSL --retry 8 --retry-all-errors --connect-timeout 15 \
    "https://api.github.com/repos/$REPO/releases?per_page=100&cachebust=$(date +%s)" |
    jq -c --arg prefix "$prefix" --arg channel "$channel" '
      [.[] | select(.draft == false)
       | select(.tag_name | startswith($prefix))
       | select(($channel == "test") or (.prerelease == false))]
      | sort_by(.published_at // .created_at) | last'
}

asset_url(){ jq -r --arg name "$2" '.assets[]? | select(.name == $name) | .browser_download_url' <<<"$1" | head -n1; }

install_channel(){
  local channel="$1" rel tag current_file current asset checksum work release_dir
  rel="$(release_json "$channel")"
  [[ -n "$rel" && "$rel" != "null" ]] || fail "No release found for channel $channel"
  tag="$(jq -r '.tag_name' <<<"$rel")"
  current_file="$STATE_ROOT/${channel}-version"
  current="$(cat "$current_file" 2>/dev/null || true)"
  if [[ "$current" == "$tag" && $FORCE -eq 0 ]]; then
    log "$channel is current: $tag"
    return
  fi
  asset="iMonitor-EcomERP-linux-x64.tar.gz"
  local url sum_url
  url="$(asset_url "$rel" "$asset")"
  sum_url="$(asset_url "$rel" "$asset.sha256")"
  [[ -n "$url" && -n "$sum_url" ]] || fail "Linux asset/checksum missing in $tag"
  work="$(mktemp -d)"
  curl -fL --retry 8 --retry-all-errors --progress-bar "$url" -o "$work/$asset"
  curl -fsSL --retry 8 --retry-all-errors "$sum_url" -o "$work/$asset.sha256"
  (cd "$work" && sha256sum -c "$asset.sha256")
  release_dir="$ROOT/releases/$channel/$tag"
  rm -rf "$release_dir"; mkdir -p "$release_dir"
  tar -xzf "$work/$asset" -C "$release_dir"
  rm -rf "$work"
  [[ -f "$release_dir/Ecomm.dll" ]] || fail "$tag does not contain Ecomm.dll"
  ln -sfn "$release_dir" "$ROOT/$channel-current"
  printf '%s\n' "$tag" > "$current_file"
  log "Installed $channel $tag"
}

write_appsettings(){
  cat > "$ROOT/config/test.json" <<EOF
{"Database":{"Type":"MySql","MigrateOnStartup":true,"MySql":{"Server":"mysql","Port":3306,"UserId":"$MYSQL_TEST_USER","Password":"$MYSQL_TEST_PASSWORD","ConnectionString":"Server=mysql;Port=3306;Database=$MYSQL_TEST_DATABASE;User=$MYSQL_TEST_USER;Password=$MYSQL_TEST_PASSWORD;CharSet=utf8mb4;"}},"ConnectionStrings":{"MySql":"Server=mysql;Port=3306;Database=$MYSQL_TEST_DATABASE;User=$MYSQL_TEST_USER;Password=$MYSQL_TEST_PASSWORD;CharSet=utf8mb4;"},"Environment":{"Name":"Test","IsDevelopment":false,"IsProduction":false},"AllowedHosts":"*"}
EOF
  cat > "$ROOT/config/production.json" <<EOF
{"Database":{"Type":"MySql","MigrateOnStartup":true,"MySql":{"Server":"mysql","Port":3306,"UserId":"$MYSQL_PROD_USER","Password":"$MYSQL_PROD_PASSWORD","ConnectionString":"Server=mysql;Port=3306;Database=$MYSQL_PROD_DATABASE;User=$MYSQL_PROD_USER;Password=$MYSQL_PROD_PASSWORD;CharSet=utf8mb4;"}},"ConnectionStrings":{"MySql":"Server=mysql;Port=3306;Database=$MYSQL_PROD_DATABASE;User=$MYSQL_PROD_USER;Password=$MYSQL_PROD_PASSWORD;CharSet=utf8mb4;"},"Environment":{"Name":"Production","IsDevelopment":false,"IsProduction":true},"AllowedHosts":"*"}
EOF
  chmod 600 "$ROOT/config/"*.json
}

write_compose(){
  cat > "$COMPOSE_FILE" <<'EOF'
services:
  mysql:
    image: mysql:8.4
    container_name: imonitor-erp-mysql
    restart: unless-stopped
    env_file: /etc/imonitor-erp/credentials.env
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    command: ["--character-set-server=utf8mb4","--collation-server=utf8mb4_unicode_ci"]
    volumes:
      - mysql-data:/var/lib/mysql
      - ./mysql-init:/docker-entrypoint-initdb.d:ro
    networks: [imonitor]
    healthcheck:
      test: ["CMD-SHELL","mysqladmin ping -h localhost -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 20

  phpmyadmin:
    image: phpmyadmin:5
    container_name: imonitor-erp-phpmyadmin
    restart: unless-stopped
    depends_on:
      mysql: { condition: service_healthy }
    environment:
      PMA_HOST: mysql
      PMA_PORT: 3306
      UPLOAD_LIMIT: 256M
    ports: ["${PHPMYADMIN_PORT}:80"]
    networks: [imonitor]

  erp-test:
    image: mcr.microsoft.com/dotnet/aspnet:8.0
    container_name: imonitor-erp-test
    restart: unless-stopped
    depends_on:
      mysql: { condition: service_healthy }
    working_dir: /app
    command: ["dotnet","Ecomm.dll","--urls","http://0.0.0.0:8080"]
    environment:
      ASPNETCORE_ENVIRONMENT: Test
      DOTNET_SYSTEM_GLOBALIZATION_INVARIANT: "false"
    volumes:
      - ./test-current:/app:ro
      - ./config/test.json:/app/appsettings.json:ro
      - dataprotection-test:/root/.aspnet/DataProtection-Keys
      - diagnostics-test:/app/App_Data/Diagnostics
    ports: ["${TEST_PORT}:8080"]
    networks: [imonitor]

  erp-production:
    image: mcr.microsoft.com/dotnet/aspnet:8.0
    container_name: imonitor-erp-production
    restart: unless-stopped
    depends_on:
      mysql: { condition: service_healthy }
    working_dir: /app
    command: ["dotnet","Ecomm.dll","--urls","http://0.0.0.0:8080"]
    environment:
      ASPNETCORE_ENVIRONMENT: Production
      DOTNET_SYSTEM_GLOBALIZATION_INVARIANT: "false"
    volumes:
      - ./master-current:/app:ro
      - ./config/production.json:/app/appsettings.json:ro
      - dataprotection-production:/root/.aspnet/DataProtection-Keys
      - diagnostics-production:/app/App_Data/Diagnostics
    ports: ["${PROD_PORT}:8080"]
    networks: [imonitor]

networks:
  imonitor:
volumes:
  mysql-data:
  dataprotection-test:
  dataprotection-production:
  diagnostics-test:
  diagnostics-production:
EOF
}

write_control(){
  cat > /usr/local/sbin/imonitor-erpctl <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=/opt/imonitor-erp
CREDS=/etc/imonitor-erp/credentials.env
[[ $EUID -eq 0 ]] || { echo "Use sudo." >&2; exit 1; }
set -a; source "$CREDS"; set +a
cd "$ROOT"
case "${1:-status}" in
  status) docker compose ps ;;
  start) docker compose up -d ;;
  stop) docker compose stop ;;
  restart) docker compose restart "${2:-}" ;;
  logs) docker compose logs --tail="${2:-200}" "${3:-}" ;;
  credentials)
    echo "Credentials file: $CREDS (root-only)"
    cat "$CREDS"
    ;;
  mysql)
    docker exec -it imonitor-erp-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD"
    ;;
  update-test) /usr/local/lib/imonitor-erp/installer.sh --channel test --update-only ;;
  update-production) /usr/local/lib/imonitor-erp/installer.sh --channel master --update-only ;;
  update-all) /usr/local/lib/imonitor-erp/installer.sh --channel both --update-only ;;
  *) echo "Usage: imonitor-erpctl {status|start|stop|restart [service]|logs [lines] [service]|credentials|mysql|update-test|update-production|update-all}" >&2; exit 2 ;;
esac
EOF
  chmod 750 /usr/local/sbin/imonitor-erpctl
  ln -sfn /usr/local/sbin/imonitor-erpctl /usr/local/bin/imonitor-erpctl
}

install_self_and_timers(){
  mkdir -p /usr/local/lib/imonitor-erp
  curl -fsSL --retry 5 "https://raw.githubusercontent.com/$REPO/main/scripts/Install-iMonitorERP-v2.0.0.sh?cb=$(date +%s)" -o /usr/local/lib/imonitor-erp/installer.sh
  chmod 750 /usr/local/lib/imonitor-erp/installer.sh
  cat > /etc/systemd/system/imonitor-erp.service <<EOF
[Unit]
Description=iMonitor ERP dual-channel Docker stack
Requires=docker.service
After=docker.service network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ROOT
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/imonitor-erp-update-test.service <<EOF
[Unit]
Description=Update iMonitor ERP test channel
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/lib/imonitor-erp/installer.sh --channel test --update-only
EOF
  cat > /etc/systemd/system/imonitor-erp-update-test.timer <<EOF
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Persistent=true
RandomizedDelaySec=30
[Install]
WantedBy=timers.target
EOF
  cat > /etc/systemd/system/imonitor-erp-update-production.service <<EOF
[Unit]
Description=Update iMonitor ERP production channel
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/lib/imonitor-erp/installer.sh --channel master --update-only
EOF
  cat > /etc/systemd/system/imonitor-erp-update-production.timer <<EOF
[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=3h
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable imonitor-erp.service imonitor-erp-update-test.timer imonitor-erp-update-production.timer >/dev/null
  systemctl start imonitor-erp-update-test.timer imonitor-erp-update-production.timer
}

health_check(){
  local failed=0
  if [[ "$CHANNEL" == "both" || "$CHANNEL" == "test" ]]; then
    curl -fsS --retry 20 --retry-delay 3 "http://127.0.0.1:$TEST_PORT/" >/dev/null || failed=1
  fi
  if [[ "$CHANNEL" == "both" || "$CHANNEL" == "master" ]]; then
    curl -fsS --retry 20 --retry-delay 3 "http://127.0.0.1:$PROD_PORT/" >/dev/null || failed=1
  fi
  (( failed == 0 )) || { docker compose ps; docker compose logs --tail=150; fail "Health check failed."; }
}

install_dependencies
create_credentials
write_mysql_init
[[ "$CHANNEL" == "both" || "$CHANNEL" == "test" ]] && install_channel test
[[ "$CHANNEL" == "both" || "$CHANNEL" == "master" ]] && install_channel master
write_appsettings
write_compose
write_control
install_self_and_timers
cd "$ROOT"
docker compose --env-file "$CREDENTIALS" up -d --force-recreate
health_check
log "Installer v$VERSION completed"
echo "Test:       http://SERVER-IP:$TEST_PORT"
echo "Production: http://SERVER-IP:$PROD_PORT"
echo "phpMyAdmin: http://SERVER-IP:$PHPMYADMIN_PORT"
echo "MySQL root password: sudo imonitor-erpctl credentials"
