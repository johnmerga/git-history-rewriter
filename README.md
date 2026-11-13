# git-history-rewriter

`rewriter.sh` clones a source repo, reassigns every commit's author/committer identity to a
fixed pool of engineers, and force-pushes the rewritten history to a target repo.

## Requirements

- `git`
- [`git-filter-repo`](https://github.com/newren/git-filter-repo)
- SSH access (or a PAT) to both the source and target repos

### Installing git-filter-repo

```bash
python3 -m venv env
source env/bin/activate
pip3 install git-filter-repo
```

Keep the venv active in the shell that runs `rewriter.sh` — the script looks for
`git-filter-repo` on `PATH`.

On distros that ship a PEP 668 "externally managed" Python (Arch, Debian, Ubuntu, Fedora),
`pip3 install git-filter-repo` outside a venv fails with:

```
error: externally-managed-environment
```

The venv above is the fix. Alternatives, if you'd rather not activate one each time:

```bash
pacman -S git-filter-repo     # Arch — system package
brew install git-filter-repo  # macOS
pipx install git-filter-repo  # any distro, isolated but always on PATH
```

Avoid `--break-system-packages`; it does what it says.

## Configuration

All settings are environment variables; the defaults are at the top of `rewriter.sh`.

| Variable | Purpose |
| --- | --- |
| `SOURCE_REPO` | Repo to read history from (mirror-cloned, never modified) |
| `TARGET_REPO` | Repo the rewritten history is force-pushed to |
| `ENGINEERS` | Round-robin identity pool, one `Name\|email` entry per line (edit in the script) |
| `AUTHORS_MAP_B64` | Optional. Fixed author map, base64 encoded. Replaces round-robin; see below |
| `AUTHORS_MAP` | Optional. Same, as a file path |
| `SOURCE_SSH_KEY` | Optional. Private key text that can read the source (e.g. a deploy key) |
| `SOURCE_CACHE` | Optional. Folder for a mirror of the source kept between runs; later runs fetch only new commits. Other jobs can read from it; it is locked while it is updated (`$SOURCE_CACHE.lock`) |
| `TARGET_SSH_KEY` | Optional. Private key text with write access to the target; used for the push |
| `GITHUB_PAT` | Optional. Token for the push over HTTPS, when `TARGET_SSH_KEY` is not set |
| `WORK_DIR` | Optional. Scratch folder; a fixed one is reused (emptied) on each run |
| `PUSH` | `0` (default) = rewrite locally only. `1`/`true`/`yes`/`on` = force-push to the target |

### Author map

With an author map every commit email is mapped to a fixed engineer, so the same input always
gives the same commit IDs and a rerun only adds the new commits to the target. The run fails if
a branch or tag has an author or committer email that is neither in the map nor an engineer
email. Besides authors and committers, it rewrites `Author:`, `Co-authored-by:` and
`Signed-off-by:` lines and any other mention of a mapped email in commit messages.

One line per email, `#` lines ignored:

```
# <email as it appears in commits>   <Engineer name>|<engineer email>
dev.one@example.com    AA-Engineer-1|engineer1-a-1@teambase.click
```

Encode it for `AUTHORS_MAP_B64` with `base64 -w0 authors.map`.

Only branches and tags are copied; GitHub's `refs/pull/*` are dropped.

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
git -C /tmp/git-rewrite-workdir-XXXXXX/repo-mirror log --all --format='%an <%ae>' | sort -u
```

Nothing is cleaned up in local mode — delete the work dir yourself when done. In push mode the
work dir is removed after a successful push.

## How it works

1. **Mirror clone** the source repo into a temp dir (`/tmp/git-rewrite-workdir-XXXXXX`).
2. **Collect unique authors** via `git log --all --format="%an|%ae"`.
3. **Build a `.mailmap`**, assigning each distinct original author to an engineer round-robin.
   The mapping is per-author, not per-commit, so one original author always maps to the same
   engineer across the whole history.
   - Authors whose email is **already in the engineer pool are skipped** — no mailmap entry is
     written and the round-robin index does not advance, so their commits keep their existing
     identity. The match is case-insensitive on the email.
   - If *every* author is already in the pool the mailmap is empty, the `git-filter-repo` step is
     skipped entirely, and the history is pushed as-is.
4. **Rewrite** with `git filter-repo --mailmap`.
5. **Stop here** unless pushing was requested — the mirror path is printed for inspection.
6. **Push** all branches and tags to the target with `--force`.
7. **Clean up** the temp working dir.

## Notes

- The push is a **force push** — the target repo's history is overwritten. Use a throwaway or
  dedicated target. This is why it is opt-in.
- The source repo is only ever read from; the rewrite happens in the temp clone.
- Rewriting changes every commit SHA of affected commits, so any clones of the target must re-clone.
- If the push fails, check the target repo's branch protection rules / rulesets and your auth.
