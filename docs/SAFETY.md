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
