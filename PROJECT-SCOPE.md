# Project Scope

## Supported in v0.25.4

- Sequential MSI and EXE intake
- Native installer metadata, hash, and signature inspection
- Best-effort EXE framework recognition and command suggestions
- Explicit technician approval of EXE commands
- Optional EXE uninstall command with an advisory validation warning when blank
- MSI deployment types for MSI packages
- Script deployment types for EXE packages
- MSI product-code, file, registry, and PowerShell detection where applicable
- Standardized and verified source copy
- Application folder placement
- Distribution point or distribution-point-group distribution
- Per-application Import Only or Available behavior
- Per-application collection targeting for Available deployments
- Selected-item and full-queue validation
- Connection gating, live processing state, safe cancellation, rollback, manifests, and transaction logging
- Best-effort associated-icon extraction, preview, technician image override, no-icon selection, ConfigMgr application icon assignment, and manifest logging

## Architectural rules

Queue items remain the source of truth. The workflow tabs are synchronized editors and read-only review surfaces. Processing revalidates each application immediately before commit.

EXE analysis is dependency-free and best effort. Suggested commands must be clearly labeled and explicitly approved. Unknown EXE installers require manual commands and detection settings.

Icon selection is optional and never blocks application creation.

## Deferred

MSIX, PSADT, Required deployments, supersedence, dependencies, arbitrary package frameworks, online icon search, vendor icon libraries, automatic brand matching, and image editing.
