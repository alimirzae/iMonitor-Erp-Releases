# Deployment Manager (port 8099) — Disk retention policy

Updated 2026-10-21. Source: `installer/PosiranERP.Installer.Web/OrchestratorService.cs`.

## Problem
The old cleanup code used `Math.Clamp(retain, 10, 100)` for both automatic database backups and cached release archives. Therefore the operator could not enforce a five-version limit. Each frequent test deployment produced another pre-version database snapshot before cleanup, causing heavy disk usage.

## New policy
- **Five latest complete automatic pre-version backups per installation instance** (Test and Production each have an independent directory).
- **Five latest known-good release packages per product/channel**, plus packages currently installed on any sibling instance on the same root.
- Backups marked `pre-version:<tag>` are eligible for automatic pruning. **Manual/operator backups are deliberately protected** from automatic deletion; admins must manage them separately.
- Failed backup directories older than 48 hours are eligible for deletion; incomplete folders without a complete metadata file are preserved for operator review.
- The immediate rollback directory `rollback-current` is managed by the installer and is not removed by this retention policy.
- Cleanup runs after a successful version activation, and in each automatic Test update cycle even if no newer release is available.
- Directory and reparse-point checks prevent deleting arbitrary paths via directory links. An installed package of another instance is always protected.

## Release validation
Run `dotnet build installer/PosiranERP.Installer.Web/PosiranERP.Installer.Web.csproj -c Release` and workflow `Validate Unified iBOS Deployment Manager`. Deploy new Deployment Manager binary after successful validation. Old binary on port 8099 will keep old behavior until updated or restarted.

## Emergency disk shortage
If disk space is critically low *before* the new manager is deployed, an administrator should first inspect backups and identify the five newest healthy `pre-version:` backups per instance, rather than indiscriminately deleting folders. Preserve manual backups, current installation, `rollback-current`, and packages installed by other instances.

## Follow-up
Disk growth outside managed snapshots—logs, orphan stage directories, partial downloads, and installer-specific caches—should be audited separately with a size report; these are not covered by automatic backup retention.
