# Changelog

## 0.1.0 (unreleased)

- Extract the Git/GitHub worktree cleaner into a standalone Ruby CLI gem.
- Preview removals by default. Require `--apply` before changing worktrees.
- Preserve primary, base, current, detached, dirty and ignored-file checkouts.
- Keep worktrees when GitHub state is unavailable or a pull request is open.
- Verify the exact PR head and merge commit before using squash-merge evidence.
- Recheck candidates before removal and preserve branches whose tips changed.
- Include executable safety tests and built-gem installation verification.
