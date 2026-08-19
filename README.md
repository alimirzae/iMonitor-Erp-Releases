# iMonitor ERP Release Center

Public release/bootstrap repository for iMonitor ERP. Application source code remains in the development repository; this repository contains channel metadata, server compose files and one-command installers/updaters.

## Server channels

- `main` — production/stable server channel, default port `8080`
- `test` — test/preview server channel, default port `8081`

Each source commit publishes a container to GHCR and an immutable GitHub Release. `server/channels/main.json` and `server/channels/test.json` identify the currently promoted image/commit for each channel. Server installers always read this repository before updating.

## Ubuntu / Debian / WSL — one command

Production:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.sh | sudo bash -s -- --channel main
```

Test:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.sh | sudo bash -s -- --channel test
```

The installer can install Docker when missing, creates persistent PostgreSQL/Redis/RabbitMQ volumes, generates secrets, runs Alembic migrations, creates the first administrator/context on first install, starts the API and installs a 5-minute systemd auto-update timer when systemd is available.

For the first PuyaTools test installation you can explicitly set the initial context:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.sh | sudo bash -s -- \
  --channel test \
  --company-code PUYATOOLS \
  --company-name PuyaTools \
  --book-code MAIN \
  --book-name Main
```

If `--admin-password` is omitted, a random initial password is printed once. To use a private GHCR package, export `GHCR_TOKEN` and optionally `GHCR_USER` before running the installer; Docker credentials remain on that machine for later updates.

## Windows / Windows Server — one command

Open PowerShell as Administrator.

Production:

```powershell
irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.ps1 -OutFile "$env:TEMP\Install-iMonitorERP-Server.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\Install-iMonitorERP-Server.ps1" -Channel main
```

Test:

```powershell
irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.ps1 -OutFile "$env:TEMP\Install-iMonitorERP-Server.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\Install-iMonitorERP-Server.ps1" -Channel test
```

The Windows installer enables/installs WSL2 + Ubuntu when required, delegates the Linux stack installation, configures the Windows port proxy/firewall and registers an automatic update task. A reboot may be required during the first WSL installation; a resume task continues setup afterwards.

## Update and rollback behavior

Running the same installer is always safe and is also the manual update command. Before schema migration, an existing PostgreSQL database is backed up. Then the selected channel image is pulled, `alembic upgrade head` runs, and only after a successful migration is the API started. Persistent database/message/cache volumes are not recreated.

Channel metadata contains the source commit and exact image reference. Immutable releases allow operators to identify or pin an earlier build when rollback is required. Database rollback is intentionally not automatic; restore uses the pre-update PostgreSQL backup when a schema downgrade is necessary.

## Server files

- `server/compose.yml` — PostgreSQL + Redis + RabbitMQ + iMonitor FastAPI runtime
- `server/channels/main.env` / `test.env` — machine-readable channel settings
- `server/channels/main.json` / `test.json` — promoted release manifest
- `scripts/Install-iMonitorERP-Server.sh` — Ubuntu/Debian/WSL installer + updater
- `scripts/Install-iMonitorERP-Server.ps1` — Windows/Windows Server WSL installer + updater

## Security

No production password, JWT signing secret, database credential or GHCR token belongs in this repository. Installers generate host-local secrets and store them in the protected local installation directory. Legacy PuyaTools/Ecomm database credentials are also local-only and must be read-only.
