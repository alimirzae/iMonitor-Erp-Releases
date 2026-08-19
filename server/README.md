# iMonitor ERP Python Server Releases

This directory is the public deployment contract for the new Python iMonitor ERP. It is intentionally separate from the legacy .NET ERP manifests already present in this release repository.

## Channels

| Channel | Source branch | Container | Default HTTP port |
|---|---|---|---:|
| `main` | `alimirzae/iMonitor-ERP:main` | `ghcr.io/alimirzae/imonitor-erp:main-latest` | 8080 |
| `test` | `alimirzae/iMonitor-ERP:test` | `ghcr.io/alimirzae/imonitor-erp:test-latest` | 8081 |

Each stack contains:

- iMonitor ERP API/Gateway
- PostgreSQL 17
- Redis 8
- RabbitMQ 4
- persistent Docker volumes
- container health checks

The installer is idempotent. Running the same installer again updates containers but preserves database/message/cache volumes and the generated secrets.

## Linux — one command

Main:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.sh | sudo bash -s -- --channel main
```

Test:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.sh | sudo bash -s -- --channel test
```

Install both channels on the same server by running both commands. They use separate Compose projects, directories and volumes.

Default paths:

```text
/opt/imonitor-erp/main
/opt/imonitor-erp/test
```

Default ports:

```text
main -> 8080
test -> 8081
```

Override a port:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.sh | sudo bash -s -- --channel test --port 18081
```

## Windows Server 2022+

The Windows installer uses WSL2 because PostgreSQL, Redis and RabbitMQ are Linux containers. Run PowerShell as Administrator.

Main:

```powershell
irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.ps1 | iex
```

Test:

```powershell
$script = irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.ps1
& ([scriptblock]::Create($script)) -Channel test
```

If WSL/VirtualMachinePlatform must be enabled, the installer creates a SYSTEM startup resume task and can reboot the server. After WSL is available it runs the same Linux deployment stack and configures a Windows port proxy/firewall rule.

## Updates

Run the same install command again. Before an existing PostgreSQL stack is updated, the Linux installer creates a best-effort compressed `pg_dump` under the channel `backups` directory.

Data volumes are never deleted by the updater. `docker compose down -v` is intentionally not used.

## GHCR visibility

For anonymous one-command installs, the package `ghcr.io/alimirzae/imonitor-erp` must be Public. If it remains Private, provide credentials when running the installer:

```bash
export GHCR_USER=alimirzae
export GHCR_TOKEN='...read-packages token...'
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.sh | sudo -E bash -s -- --channel main
```

Do not store customer credentials or database passwords in this repository.

## Rolling GitHub releases

After `RELEASES_REPO_TOKEN` is configured in the private source repository, successful server builds also publish rolling releases in `alimirzae/iMonitor-Erp-Releases`:

- `imonitor-erp-main-latest`
- `imonitor-erp-test-latest`

Each rolling release contains release metadata and a small server deployment bundle. The runtime application itself is distributed as the GHCR container image.
