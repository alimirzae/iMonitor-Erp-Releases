# iMonitor ERP Release Center

Public release and deployment center for iMonitor ERP.

Repository:

https://github.com/alimirzae/iMonitor-Erp-Releases

This repository provides public installers, release manifests, Docker deployment files and automatic update mechanisms. Source code remains in development repositories.

## Products and deployment channels

### iMonitor ERP

Production and test releases for the main iMonitor ERP platform.

### iMonitor Ecom ERP

A separated ERP deployment package based on Ecomm. It uses an independent runtime name:

```
imonitor-ecom-erp
```

and does not conflict with:

```
imonitor-erp
```

## Ubuntu / Debian / WSL Installation

Supported:

- Ubuntu Server
- Debian
- Ubuntu on WSL2

Install production:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.sh | sudo bash -s -- --channel main
```

Install test:

```bash
curl -fsSL https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.sh | sudo bash -s -- --channel test
```

Features:

- Automatic Docker installation
- Container deployment
- Database persistence
- Automatic migrations
- Systemd service management
- Automatic update checker
- Release channel management

## Windows / Windows Server Installation

Supported:

- Windows Server 2019+
- Windows 10/11 Pro
- Windows 11 Enterprise

The Windows installer uses WSL2 + Ubuntu when required and configures the required services automatically.

Run PowerShell as Administrator:

Production:

```powershell
irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.ps1 -OutFile "$env:TEMP\Install-iMonitorERP-Server.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\Install-iMonitorERP-Server.ps1" -Channel main
```

Test:

```powershell
irm https://raw.githubusercontent.com/alimirzae/iMonitor-Erp-Releases/main/scripts/Install-iMonitorERP-Server.ps1 -OutFile "$env:TEMP\Install-iMonitorERP-Server.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\Install-iMonitorERP-Server.ps1" -Channel test
```

Windows deployment includes:

- WSL2 preparation
- Ubuntu environment setup
- Docker runtime
- Firewall configuration
- Port forwarding
- Automatic updates

## Automatic Updates

Servers do not need GitHub accounts or tokens for public releases.

The update flow is:

```
Ecomm Source
      |
      v
GitHub Actions Build
      |
      v
Docker Image
      |
      v
Release Manifest
      |
      v
Customer Server
```

The server periodically checks the selected release channel and updates automatically.

## Repository Structure

```
server/
  compose files
  release manifests

scripts/
  Ubuntu installers
  Windows installers

channels/
  test releases
  stable releases
```

## Security

No production passwords or private credentials are stored in this repository.

Installers generate local secrets and keep runtime configuration on the target machine.
