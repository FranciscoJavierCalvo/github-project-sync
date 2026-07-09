# Changelog

## 0.3.0 - Phase 3 Sync Selected

### Added

- Added Sync Selected button.
- Added selected-project sync workflow.
- Added pre-check confirmation summary.
- Added commit-if-needed logic.
- Added safe pull using git pull --ff-only.
- Added push after successful pull.
- Added stop-on-first-failure behaviour.
- Added final success message.
- Added automatic status refresh after sync.

### Safety

- No force push.
- No reset hard.
- No git clean.
- No branch switching.
- No automatic conflict resolution.
- Push is not attempted if pull fails.

## 0.1.0 - Phase 1 Read-Only GUI

### Added

- Initial PowerShell Windows Forms GUI
- Project loading from JSON
- Folder existence checks
- Git repository validation
- Current branch detection
- Origin remote URL detection
- Local change count
- GUI log window
- Open selected folder
- Open selected GitHub repository

### Safety

- Phase 1 is read-only
- No write Git commands are used

