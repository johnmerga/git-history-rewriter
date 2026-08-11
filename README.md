# git-history-rewriter

`rewriter.sh` clones a source repo, reassigns every commit's author/committer identity to a
fixed pool of engineers, and force-pushes the rewritten history to a target repo.

## Requirements

- `git`
- [`git-filter-repo`](https://github.com/newren/git-filter-repo) — `pip install git-filter-repo` or `brew install git-filter-repo`
- SSH access (or a PAT) to both the source and target repos

## Configuration

Edit the variables at the top of `rewriter.sh`:

| Variable | Purpose |
| --- | --- |
| `SOURCE_REPO` | Repo to read history from (mirror-cloned, never modified) |
| `TARGET_REPO` | Repo the rewritten history is force-pushed to |
| `ENGINEERS` | Identity pool, one `Name\|email` entry per line |
| `GITHUB_PAT` | Optional. If exported, the target switches to HTTPS auth with this token |
| `PUSH` | `0` (default) = rewrite locally only. `1`/`true`/`yes`/`on` = force-push to the target |

## Usage

```bash
./rewriter.sh              # rewrite locally, keep the result, push nothing
./rewriter.sh --push       # rewrite and force-push to TARGET_REPO
PUSH=1 ./rewriter.sh       # same, via env var
./rewriter.sh --help
```

**Local mode is the default.** The rewritten mirror is left in place and its path printed, so you
can inspect the result before committing to a push:

```bash
git -C /tmp/git-rewrite-workdir-<epoch>/repo-mirror log --all --format='%an <%ae>' | sort -u
```

Nothing is cleaned up in local mode — delete the work dir yourself when done. In push mode the
work dir is removed after a successful push.

## How it works

1. **Mirror clone** the source repo into a temp dir (`/tmp/git-rewrite-workdir-<epoch>`).
2. **Collect unique authors** via `git log --all --format="%an|%ae"`.
3. **Build a `.mailmap`**, assigning each distinct original author to an engineer round-robin.
   The mapping is per-author, not per-commit, so one original author always maps to the same
   engineer across the whole history.
   - Authors whose email is **already in the engineer pool are skipped** — no mailmap entry is
     written and the round-robin index does not advance, so their commits keep their existing
     identity. The match is case-insensitive on the email.
   - If *every* author is already in the pool the mailmap is empty, the `git-filter-repo` step is
     skipped entirely, and the history is pushed as-is.
4. **Rewrite** with `git filter-repo --use-mailmap --force`.
5. **Stop here** unless pushing was requested — the mirror path is printed for inspection.
6. **Push** all branches and tags to the target with `--force`.
7. **Clean up** the temp working dir.

## Notes

- The push is a **force push** — the target repo's history is overwritten. Use a throwaway or
  dedicated target. This is why it is opt-in.
- The source repo is only ever read from; the rewrite happens in the temp clone.
- Rewriting changes every commit SHA of affected commits, so any clones of the target must re-clone.
- If the push fails, check the target repo's branch protection rules / rulesets and your auth.
