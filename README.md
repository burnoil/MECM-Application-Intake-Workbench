# MECM Application Intake Workbench

A technician-focused PowerShell/WPF workbench for guarded MSI and EXE application intake into Microsoft Configuration Manager.

![MECM Application Intake Workbench v0.25.4](docs/screenshots/v0.25.4-intake-and-icon-workflow.png)

## Current release: v0.25.4

The current baseline supports:

- MSI and EXE intake in a synchronized queue
- MSI metadata and product-code extraction
- Best-effort EXE framework recognition and command suggestions
- Explicit technician approval for EXE commands
- File, registry, PowerShell, and MSI detection methods where applicable
- Import Only and Available deployments
- Application folder, collection, and distribution targeting
- Standardized and verified source-content copying
- Per-application icon extraction, preview, replacement, or no-icon selection
- Validate Selected and Validate All
- Live batch processing, rollback, cancellation after the current item, manifests, and logs

EXE command discovery and icon extraction are intentionally best effort. The technician remains responsible for reviewing commands, detection rules, targeting, and final application identity.

## Requirements

- Windows PowerShell 5.1
- Microsoft Configuration Manager console installed on the workstation
- Configuration Manager PowerShell module
- Administrator rights
- Access to the site provider and application source share
- Appropriate ConfigMgr RBAC permissions

## Getting started

1. Clone or download the repository.
2. Open `src/Start-MECMApplicationIntakeWorkbench.ps1`.
3. Replace the example startup defaults near `$script:State` and in the matching XAML fields:
   - Site code: `ABC`
   - Provider: `CM01.contoso.com`
   - Source root: `\\CM01\MECMSources$\Applications`
4. Run the script from an elevated Windows PowerShell 5.1 session.
5. Connect to MECM before adding or committing applications.

The example values are placeholders and are not expected to work unchanged in another environment.

## Safety model

- MECM-dependent actions remain disabled until connected.
- Processing revalidates each queue item before commit.
- Queue items are isolated so one failure does not automatically stop later applications.
- Source content is verified at the exact UNC path before ConfigMgr objects are created.
- EXE commands require explicit technician approval.
- Missing EXE uninstall commands warn but do not block creation.
- Icon selection is optional and does not block creation.

## Important detection note

Some vendor-supplied MSI files are wrappers around another installer and may not leave the source MSI product code registered after installation. Mozilla Firefox Enterprise MSI is one confirmed example. Do not assume MSI Product Code detection is always durable; verify the installed state on a test endpoint and use file, registry, or PowerShell detection when appropriate.

A restrained, exportable packaging-advisory feature is planned rather than a large embedded application catalog.

## Repository layout

```text
src/                Main PowerShell/WPF application
docs/screenshots/   UI screenshots
CHANGELOG.md         Release history
PROJECT-SCOPE.md     Supported and deferred scope
```

## Status

v0.25.4 is the current stable MSI, EXE, icon, and source-copy baseline. Planned follow-up work includes explicit icon selected/applied/skipped status and safer handling of known MSI-wrapper detection cases.

## License

No open-source license has been selected yet. All rights are reserved until a license file is added.
