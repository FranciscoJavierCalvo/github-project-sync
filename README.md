# GitHub Project Sync Manager

PowerShell Windows Forms GUI for checking and managing multiple local GitHub project folders from one place.

## Current Status

Phase 1 complete - read-only project status dashboard.

## Overview

GitHub Project Sync Manager loads project definitions from projects.json and performs safe read-only Git checks against each configured project.

## Phase 1 Features

- Windows Forms GUI
- Loads projects from projects.json
- Checks whether each local project folder exists
- Checks whether each folder is a Git repository
- Displays the current Git branch
- Displays the configured default branch
- Displays the actual origin remote URL
- Compares configured repo URL with actual origin remote
- Counts local modified and untracked files
- Shows clean, modified, or error status
- Opens selected local project folder
- Opens selected GitHub repository
- Writes timestamped local logs

## Safety

Phase 1 is read-only.

Phase 1 does not run git add, git commit, git pull, git push, git reset, git clean, git checkout, git merge, or git rebase.

Phase 1 only uses safe read-only Git commands:

- git rev-parse --is-inside-work-tree
- git rev-parse --abbrev-ref HEAD
- git remote get-url origin
- git status --porcelain
- git status -sb

## Files

- GitHubProjectSync-GUI.ps1 - Main GUI script
- projects.example.json - Example project configuration
- projects.json - Local project configuration, ignored by Git
- docs/ROADMAP.md - Project roadmap
- docs/SAFETY.md - Safety notes

## How to Run

Open PowerShell from the repo folder and run:

.\GitHubProjectSync-GUI.ps1

## Author

Created and maintained by Francisco Calvo.
