# Separate deployment responsibilities

This repository publishes releases for both products; deployments must be independently owned.

| Product | Setup URL | Windows service | Release | Test / Production ERP ports | Setup state |
|---|---|---|---|---|---|
| iMonitor | http://127.0.0.1:8100 | iMonitorERPDeploymentManager | imonitor-installer-preview | 8081 / 8080 | %ProgramData%\iMonitor\iMonitorERPDeploymentManager |
| Posiran | http://127.0.0.1:8099 | PosiranERPDeploymentManager | posiran-installer-preview | 8082 / 8083 | %ProgramData%\PosiranERP\DeploymentManager |

- iMonitor bootstrap: `scripts/Start-iMonitorERP-Setup.ps1`; Posiran bootstrap: `scripts/Start-PosiranERP-Setup.ps1`.
- The iMonitor installer workflow no longer republishes the Posiran installer.
- Posiran setup rejects iMonitor configuration, and only selects Posiran registered instances for installation, backups, updates, and health checks.
- Product-specific release manifests remain under `channels/imonitor/{test,master}` and `channels/posiran/{test,production}`.
- Test automatic updates are product-specific; Production upgrades remain manual.
- Installation roots, MySQL databases, config roots, IIS websites, IIS app pools, and package caches must remain distinct.

## Existing installations and cutover

**Do not run the new Posiran bootstrap over an active legacy `ERPDeploymentManager` still listening on port 8099.** That legacy manager remains untouched by GitHub publication. Before installing the new Posiran manager, inventory existing service settings and its stored instance manifests, export a backup, stop or migrate the legacy manager *only during an approved cutover*, and check that 8099 is free. The iMonitor manager uses 8100 and never replaces the old service. Preserve previous files and configuration for rollback.

```powershell
Get-Service ERPDeploymentManager,iMonitorERPDeploymentManager,PosiranERPDeploymentManager -ErrorAction SilentlyContinue
Get-NetTCPConnection -LocalPort 8099,8100,8080,8081,8082,8083 -State Listen -ErrorAction SilentlyContinue
Get-ScheduledTask | Where-Object TaskName -match 'iMonitorERP|PosiranERP|iBOS-ERP'
```

No production deploy is initiated by a source change in this repo.
