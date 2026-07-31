# Changelog

## 0.25.4

- Normalizes padded EXE publisher, version, and application metadata.
- Uses one source-path component sanitizer for preview, folder creation, copy, and ConfigMgr content locations.
- Removes trailing spaces and periods that Windows cannot preserve in directory names.
- Verifies the exact destination directory, installer file, and copied file size before ConfigMgr application creation.
- Prevents deployment types from being created with nonexistent source paths.
- Preserves v0.25.3 icon, MSI, EXE, validation, and processing behavior.

## 0.25.3

- Compacts the Intake & Queue Application Icon pane.
- Reduces the icon preview and avoids enlarging small embedded icons.
- Keeps all icon controls visible at the standard window size.

## 0.25.0

- Added best-effort installer icon extraction and local preview.
- Added per-application extracted, user-supplied, and no-icon choices.
- Added non-blocking icon quality and availability validation.
- Applies the selected icon to the ConfigMgr application.

## 0.24.6

- Frozen MSI and EXE intake baseline.
- Includes EXE framework recognition, command suggestions, technician approval, optional uninstall handling, alternate detection, validation, rollback, and batch processing.

## 0.23.6

- Frozen MSI-only workflow baseline with connection gating, guided tabs, validation, live processing, rollback, cancellation, and final summaries.
