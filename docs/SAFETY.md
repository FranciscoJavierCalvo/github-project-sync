# Safety Notes

## Phase 1 Safety

Phase 1 is read-only.

Allowed commands:

- git rev-parse --is-inside-work-tree
- git rev-parse --abbrev-ref HEAD
- git remote get-url origin
- git status --porcelain
- git status -sb

Future phases must avoid:

- git push --force
- git reset --hard
- git clean -fd
- automatic conflict resolution

Future phases should require confirmation before push and a commit message before commit.

## Phase 3 Safety

- Sync Selected runs against one selected project only.
- A pre-check summary is shown before sync.
- Commit message is required when local changes exist.
- Pull uses git pull --ff-only.
- Push is not attempted if pull fails.
- No force push.
- No reset hard.
- No git clean.
- No automatic conflict resolution.
