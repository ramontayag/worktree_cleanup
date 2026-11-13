# Worktree Cleanup

Remove finished Git worktrees. Keep checkouts that still contain work.

Worktree Cleanup checks local Git history and GitHub pull requests, then reports
what it can remove. Nothing changes until you pass `--apply`.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Installation

Requires Ruby 3.2+, Git 2.39+ and authenticated [GitHub CLI](https://cli.github.com/).
There are no runtime gem dependencies. Rails and Docker are not required.

**Distribution:** source only; no RubyGems release.

Clone the repository:

```sh
git clone https://github.com/ramontayag/worktree_cleanup.git
cd worktree_cleanup
```

Build the gem:

```sh
gem build worktree_cleanup.gemspec
```

Install version 0.1.0:

```sh
gem install --user-install ./worktree_cleanup-0.1.0.gem
```

Add Ruby's user executable directory to your shell's `PATH`, if needed:

```sh
export PATH="$(ruby -r rubygems -e 'puts Gem.user_dir')/bin:$PATH"
```

## Get started

```sh
cd /path/to/your/primary-checkout
git fetch origin
worktree-cleanup
```

```sh
# Review the report, then apply the removals you expect:
worktree-cleanup --apply
```

## Usage

Preview removals from your primary checkout:

```sh
worktree-cleanup
```

Compare this illustrative report with your repository's output:

```text
Worktree cleanup for .
Base ref: origin/main

Ready to remove (1):
  .worktrees/finished-task  (branch: finished-task)

Keeping (1):
  has uncommitted changes or ignored files (1):
    .worktrees/unfinished-task

Dry run. Nothing was removed. Run again with --apply to remove these worktrees.
```

Choose another repository and base; retain local branches after removing worktrees:

```sh
worktree-cleanup --repo /path/to/repository --base origin/develop --keep-branches --apply
```

### Removal rules

- The primary checkout, base branch checkout and your current worktree stay.
- Staged, unstaged, untracked and ignored files keep a worktree. This includes
  local `.env` files. Back up or remove ignored build outputs yourself before
  retrying; there is no force option.
- Index entries marked `assume-unchanged` or `skip-worktree` keep a worktree,
  even when Git status hides their edits. The tool does not clear these flags.
- Detached worktrees and branches with open pull requests stay. If GitHub cannot
  be queried, worktrees stay even when local history shows a merge.
- A clean worktree needs proof: its tip is in the base ref, or its exact tip
  matches a merged PR targeting that branch and the PR's merge commit is in the
  local base ref. New commits after a squash merge do not count as merged.
- Apply rechecks candidates before removal. Git must accept removal without
  `--force`. Locked worktrees and worktrees containing submodules can be refused;
  a refusal is reported and their local branches stay.
- Local branches are deleted by default; use `--keep-branches` to retain them.
  Remote branches are never deleted.

### Safety limits

Keep repositories idle while applying cleanup.
Do not expect an atomic lock against other Git processes or pull request changes.
Fetch before trusting local refs; the tool does not fetch automatically.
Local refs are evidence of your last fetch, not live server state.
Only GitHub repositories are supported. Authenticate with `gh auth login`.
Review the dry run before applying cleanup.

The tool reads up to 500 recent PRs and separately checks open PRs. Older squash
merges without local ancestry can stay because the proof is missing. If the open
PR query reaches its limit, state is treated as unknown and worktrees stay.

## Options

| Option | Purpose |
| --- | --- |
| `--repo PATH` | Inspect another repository; default: current repository. |
| `--base REF` | Check merged work against this ref; default: `origin/main`. |
| `--apply` | Remove eligible worktrees and their local branches. |
| `--keep-branches` | Retain local branches after worktree removal. |
| `--help` | Show usage. |
| `--version` | Show the gem version. |

Exit status: `0` for a completed report/apply, `1` for a removal failure, and `2`
for invalid arguments or an unavailable repository/base ref. A successful report
can keep every worktree; read its reasons rather than treating success as proof
that all work was merged.

## Contributing

Install development dependencies:

```sh
bundle install
```

Run the tests:

```sh
bundle exec bin/test
```

## License

Use under the [MIT License](LICENSE). Copyright 2026 Ramon Tayag.
