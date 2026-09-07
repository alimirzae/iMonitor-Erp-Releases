# Posiran ERP White-label Contract

این Overlay متعلق به **Posiran ERP / پوزایران ERP** است و منبع حقیقت برند برای `posiran_test` و `posiran_production` محسوب می‌شود.

- Website: https://www.posiran.ir/
- Test branch / IIS: `posiran_test` / `PosiranERP-Test` / `8082`
- Production branch / IIS: `posiran_production` / `PosiranERP-Production` / `8083`
- UI/Logo/Theme/Support must never fall back to iMonitor branding.
- Support phone/email remain empty until verified from Posiran's official source; another brand's contact details must never be substituted.
- Public packages do not contain `appsettings.json`.
- The external guard in the release repository restores this overlay after overwrite/force-push.

GitHub Branch Protection/Rulesets are still the preventive control for blocking force-push; the guard is the recovery control.
