# GitHub Project Sync Manager

A PowerShell Windows Forms GUI tool for safely managing and synchronising multiple local GitHub project folders from one place.

## Overview

GitHub Project Sync Manager was created to make it easier to manage several local GitHub repositories stored under the same projects folder.

The tool provides a single GUI where projects can be loaded, checked, committed, pulled, pushed, synchronised, reported on, opened in Explorer, and opened in GitHub.

The project is designed around safe Git operations. It avoids destructive commands and blocks risky actions such as remote mismatches, detached HEAD states, merge conflicts, and unsafe write operations.

## Current status

The project is considered functionally complete as of Phase 6.

Implemented phases:

- Phase 1: Base project/status GUI
- Phase 2: Manual selected-project Git actions
- Phase 3: Sync Selected workflow
- Phase 4: Preview Sync All and Sync All
- Phase 5: Reporting and enhanced export bundle
- Phase 6: Simple Add Project workflow with local folder creation and safe Git initialisation

## Key features

### Project inventory

The GUI loads projects from projects.json and displays:

- Project name
- Local folder status
- Git repository status
- Current branch
- Default branch
- Local status
- Number of local changes
- Ahead/behind summary
- Remote match status
- Action allowed status
- Last checked time
- Last action
- Last result
- Origin remote URL
- Local path

### Status checks

The tool validates each configured project and identifies:

- Missing folders
- Folders that are not Git repositories
- Missing Git installation
- Missing origin remotes
- Remote URL mismatches
- Detached HEAD states
- Merge conflicts
- Local modifications
- Clean working trees

Rows are colour-coded:

- Green: clean/safe
- Yellow: modified but generally safe
- Red: blocked or unsafe

### Selected project actions

For a selected project, the GUI supports:

- Pull Selected
- Commit Selected
- Push Selected
- Sync Selected
- Open Folder
- Open GitHub Repo
- Details

### Sync Selected

Sync Selected performs a safe end-to-end workflow for one project:

1. Validate project safety.
2. Check for local changes.
3. Require a commit message if local changes exist.
4. Stage changes with git add .
5. Commit changes.
6. Pull latest changes using fast-forward only.
7. Push the current branch to origin.

Safety rules:

- No force push
- No git reset --hard
- No git clean
- No branch switching
- No automatic conflict resolution
- Push is not attempted if pull fails

### Preview Sync All

Preview Sync All provides a dry-run summary before any multi-project sync.

It shows safe projects, blocked projects, clean projects, modified projects, and the planned action per project.

No Git write commands are executed during Preview Sync All.

### Sync All

Sync All safely synchronises all projects that pass validation.

Behaviour:

- Processes safe projects one by one
- Skips blocked projects
- Requires a commit message if any safe project has local changes
- Stops on the first failure
- Uses fast-forward-only pulls
- Does not force push
- Does not reset or clean repositories

### Add Project

Phase 6 introduced the simplified Add Project workflow.

The user enters a project name in the GUI. The same name is used for the local folder name, GitHub repository name, and project display name.

The GitHub owner is inferred from existing repository URLs in projects.json.

The Add Project workflow can:

1. Add the project to projects.json.
2. Create the local folder if it does not exist.
3. Initialise Git safely if needed.
4. Add origin if missing.
5. Create a starter README.md if needed.
6. Create an initial commit if needed.
7. Attempt a normal push to origin/main.

The GitHub repository itself must be created manually in the browser. GitHub CLI is not required.

### Repair existing added project

If a project already exists in projects.json, typing the same project name and clicking Add Project offers a repair/check flow.

This can be used when:

- The project was added before the folder existed
- The folder was deleted and needs recreating
- Git needs to be initialised
- Origin needs to be added
- An initial commit needs to be created
- The first push needs to be retried

### Reports

The Export Report button creates an enhanced report bundle in TXT, CSV, and JSON format.

Reports include overall totals, per-project status, branch details, local status, change counts, remote match state, last action/result, and the visible GUI log.

Reports are created under the local reports folder.

## Configuration

Projects are configured in projects.json.

Example:

```json
[
  {
    "Name": "Example Project",
    "LocalPath": "C:\\Users\\YourUser\\OneDrive\\GitHub Projects\\example-project",
    "RepoUrl": "https://github.com/YourGitHubAccount/example-project.git",
    "DefaultBranch": "main"
  }
]
```

Recommended practice:

- Track projects.example.json in GitHub.
- Keep projects.json local to the machine because it contains user-specific local paths.

## How to use

### Start the GUI

```powershell
.\GitHubProjectSync-GUI.ps1
```

### Load projects

Click Load Projects.

### Check status

Click Check Status.

### Commit selected project

1. Select a project.
2. Enter a commit message.
3. Click Commit Selected.

### Pull selected project

1. Select a project.
2. Click Pull Selected.

### Push selected project

1. Select a project.
2. Click Push Selected.

### Sync selected project

1. Select a project.
2. Enter a commit message if local changes exist.
3. Click Sync Selected.

### Preview Sync All

Click Preview Sync All to review the dry-run output.

### Sync All

1. Enter a commit message if any safe project has local changes.
2. Click Sync All.

### Add a new project

1. Create the GitHub repository manually in the browser.
2. Open the GUI.
3. Enter the project/repo/folder name in the Project name box.
4. Click Add Project.

The tool will create the local folder if missing, update projects.json, initialise Git safely, add origin, create README.md and an initial commit if needed, and attempt a normal push.

## Safety design

The tool intentionally avoids destructive Git operations.

The following commands are not used:

- git reset --hard
- git clean
- git push --force
- automatic conflict resolution

The tool blocks write actions when:

- The folder is missing
- The folder is not a Git repository
- The configured repo URL does not match the actual origin
- The repository is in detached HEAD state
- Merge conflicts are detected
- The current branch is unknown

## Recommended daily workflow

1. Open the GUI.
2. Click Check Status.
3. Review red/yellow rows.
4. Enter a commit message.
5. Use Sync Selected for individual projects.
6. Use Preview Sync All before running Sync All.
7. Export a report when needed.

## Files and folders

Typical repo layout:

```text
github-project-sync
|-- GitHubProjectSync-GUI.ps1
|-- README.md
|-- CHANGELOG.md
|-- projects.example.json
|-- projects.json
|-- docs
|-- logs
|-- reports
```

Recommended Git tracking:

Track:

- GitHubProjectSync-GUI.ps1
- README.md
- CHANGELOG.md
- projects.example.json
- docs

Ignore locally generated/runtime files:

- projects.json
- logs
- reports
- backup files
- temporary patch scripts
- local cleanup archive

## Requirements

- Windows
- PowerShell 5.1
- Git installed and available in PATH
- Access to GitHub repositories using normal Git authentication

GitHub CLI is not required.

## Status

Project status: functionally complete.

Future optional improvements:

- Remove/deactivate project workflow
- Editable GitHub owner/default branch settings
- Persistent last action history
- UI resizing improvements
- Optional per-project commit messages

## Optional EXE packaging

The PowerShell script remains the source of truth for this project:

```text
GitHubProjectSync-GUI.ps1
```

An EXE can optionally be generated as a convenience wrapper for easier launching.

The generated EXE should be treated as a release artefact only. Any code changes should be made in the `.ps1` file first, tested there, and then rebuilt into a new EXE.

### Build script

The repo includes:

```powershell
Build-GitHubProjectSyncManagerExe.ps1
```

This script builds:

```text
release\GitHubProjectSyncManager.exe
```

By default, the build script deletes the previous EXE with the same name before generating a new one.

### Build command

Run from the repo root:

```powershell
.\Build-GitHubProjectSyncManagerExe.ps1
```

Optional examples:

```powershell
.\Build-GitHubProjectSyncManagerExe.ps1 -OpenOutputFolder
```

```powershell
.\Build-GitHubProjectSyncManagerExe.ps1 -KeepPrevious
```

### Requirements

- Windows PowerShell 5.1
- GitHubProjectSync-GUI.ps1 in the repo root
- PS2EXE available as `Invoke-ps2exe` or `ps2exe`

If PS2EXE is not available, the build script will stop safely and explain what is missing.

### Recommended workflow

1. Make changes to `GitHubProjectSync-GUI.ps1`.
2. Test the `.ps1` version first.
3. Run `Build-GitHubProjectSyncManagerExe.ps1`.
4. Test the generated EXE.
5. Commit the source/script changes.

The EXE is ignored by default via `.gitignore`. If a binary release is needed, publish the EXE separately as a release artefact rather than treating it as the source of truth.
