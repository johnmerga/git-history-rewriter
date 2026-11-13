#!/bin/bash
# Clones a source repo, replaces every commit's author/committer with an engineer identity, and
# optionally force-pushes all branches and tags to a target repo. See README.md.
set -euo pipefail

# --- Configuration (every value can be overridden from the environment) ---
SOURCE_REPO="${SOURCE_REPO:-git@github.com:Mereb-Tech/realgaming-store-api.git}"
TARGET_REPO="${TARGET_REPO:-git@github.com:A-Manage-1a/AA-StoreService.git}"

# Round-robin pool, used only when no author map is given
declare -a ENGINEERS=(
    "AA-Engineer-1|engineer1-a-1@teambase.click"
    "AA-Engineer-2|engineer2-a-1@teambase.click"
    "AA-Engineer-3|engineer3-a-1@teambase.click"
)

# Optional inputs:
#   AUTHORS_MAP_B64 / AUTHORS_MAP  fixed map (base64 text / file path); every commit email must be in it
#   SOURCE_SSH_KEY                 private key (text) that can read SOURCE_REPO
#   SOURCE_CACHE                   folder for a mirror of SOURCE_REPO kept between runs; only new
#                                  commits are fetched, and other jobs (deploys) can read from it
#   TARGET_SSH_KEY                 private key (text) with write access to TARGET_REPO
#   GITHUB_PAT                     token with Contents: write on TARGET_REPO (when no TARGET_SSH_KEY)
#   WORK_DIR                       scratch folder (default: a new folder under /tmp)
#   PUSH                           1/true/yes/on = force-push; default: rewrite locally only
PUSH="${PUSH:-0}"

usage() {
    echo "Usage: $0 [--push|--no-push]"
    echo "  Rewrites history locally by default; --push force-pushes to TARGET_REPO."
    echo "  Settings are environment variables; see the top of this script or README.md."
}

for arg in "$@"; do
    case "$arg" in
        --push) PUSH=1 ;;
        --no-push) PUSH=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$arg' (try --help)"; exit 1 ;;
    esac
done

case "$PUSH" in
    1|true|yes|on) PUSH=1 ;;
    *)             PUSH=0 ;;
esac

if [ "$PUSH" = 1 ] && [ -z "${TARGET_SSH_KEY:-}" ] && [ -z "${GITHUB_PAT:-}" ]; then
    echo "ERROR: --push needs TARGET_SSH_KEY or GITHUB_PAT (write access on $TARGET_REPO)."
    exit 1
fi
command -v git-filter-repo >/dev/null || {
    echo "ERROR: git-filter-repo not found. See README.md, 'Installing git-filter-repo'."
    exit 1
}

# --- Setup ---
WORK_DIR="${WORK_DIR:-$(mktemp -d /tmp/git-rewrite-workdir-XXXXXX)}"
KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$KEY_DIR"' EXIT
mkdir -p "$WORK_DIR"
MIRROR="$WORK_DIR/repo-mirror"
rm -rf "$MIRROR"

# Prints a GIT_SSH_COMMAND that uses only the given key (key text in $1, file name in $2)
ssh_with_key() {
    local file="$KEY_DIR/$2"
    printf '%s\n' "$1" > "$file"
    chmod 600 "$file"
    echo "ssh -i $file -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
}

SOURCE_GIT=(git)
if [ -n "${SOURCE_SSH_KEY:-}" ]; then
    SOURCE_GIT=(env GIT_SSH_COMMAND="$(ssh_with_key "$SOURCE_SSH_KEY" source_key)" git)
fi

# Branches and tags only: GitHub's pull request refs are not ours to copy.
if [ -n "${SOURCE_CACHE:-}" ]; then
    mkdir -p "$(dirname "$SOURCE_CACHE")"
    exec 9>"$SOURCE_CACHE.lock"
    flock 9   # deploys read the same cache
    if [ ! -d "$SOURCE_CACHE/objects" ]; then
        echo "Creating the source cache at $SOURCE_CACHE..."
        git init --quiet --bare "$SOURCE_CACHE"
        git -C "$SOURCE_CACHE" remote add origin "$SOURCE_REPO"
        git -C "$SOURCE_CACHE" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
        git -C "$SOURCE_CACHE" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
    fi
    echo "Fetching $SOURCE_REPO into the cache..."
    git -C "$SOURCE_CACHE" remote set-url origin "$SOURCE_REPO"
    "${SOURCE_GIT[@]}" -C "$SOURCE_CACHE" fetch --quiet --prune origin
    git clone --quiet --mirror "$SOURCE_CACHE" "$MIRROR"
    flock -u 9
else
    echo "Cloning $SOURCE_REPO..."
    "${SOURCE_GIT[@]}" clone --quiet --mirror "$SOURCE_REPO" "$MIRROR"
fi
cd "$MIRROR"
git for-each-ref --format='delete %(refname)' refs/pull | git update-ref --stdin

# --- Build the rewrite rules ---
FILTER_ARGS=()
if [ -n "${AUTHORS_MAP_B64:-}" ] || [ -n "${AUTHORS_MAP:-}" ]; then
    # Fixed map: the same input always gives the same commit IDs, so reruns only add new commits.
    MAP_FILE="$KEY_DIR/authors.map"
    if [ -n "${AUTHORS_MAP_B64:-}" ]; then
        printf '%s' "$AUTHORS_MAP_B64" | base64 -d > "$MAP_FILE"
    else
        cp "$AUTHORS_MAP" "$MAP_FILE"
    fi
    git log --branches --tags --format='%ae%n%ce' | sort -u > "$WORK_DIR/emails.txt"

    python3 - "$MAP_FILE" "$WORK_DIR" <<'PY'
import re, sys

map_file, work = sys.argv[1], sys.argv[2]
mapping, pool = {}, set()
for n, line in enumerate(open(map_file), 1):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    parts = line.split()
    if len(parts) < 2 or '|' not in parts[-1]:
        sys.exit(f"ERROR: author map line {n}: expected '<email> <Name>|<email>'")
    old = parts[0]
    name, email = line[len(old):].strip().rsplit('|', 1)
    mapping[old.lower()] = (name.strip(), email.strip())
    pool.add(email.strip().lower())

emails = [e.strip() for e in open(f"{work}/emails.txt") if e.strip()]
unknown = [e for e in emails if e.lower() not in mapping and e.lower() not in pool]
if unknown:
    print("ERROR: these commit emails are not in the author map:", file=sys.stderr)
    for e in unknown:
        print(f"  {e}", file=sys.stderr)
    sys.exit(1)

with open(f"{work}/mailmap", "w") as mm, open(f"{work}/messages.txt", "w") as msg:
    for e in emails:
        if e.lower() not in mapping:
            continue  # already a pool identity
        name, new = mapping[e.lower()]
        mm.write(f"{name} <{new}> <{e}>\n")
        # "Author: X <e>" lines in squash messages, Co-authored-by and Signed-off-by trailers,
        # then any other mention of the email. Regex rules only: git-filter-repo applies literal
        # rules before regex rules, which would replace the email before the name rule saw it.
        msg.write(f"regex:(?mi)^(\\s*(?:author|co-authored-by|signed-off-by):\\s*)[^<\\n]*<{re.escape(e)}>==>\\1{name} <{new}>\n")
        msg.write(f"regex:(?i){re.escape(e)}==>{new}\n")
print(f"{sum(1 for e in emails if e.lower() in mapping)} emails remapped, "
      f"{sum(1 for e in emails if e.lower() not in mapping)} already in the pool")
PY
    FILTER_ARGS=(--mailmap "$WORK_DIR/mailmap" --replace-message "$WORK_DIR/messages.txt")
else
    # Round-robin: each distinct author gets the next engineer; pool emails are left alone.
    MAILMAP_FILE="$WORK_DIR/mailmap"
    : > "$MAILMAP_FILE"
    git log --all --format="%an|%ae" | sort -u > "$WORK_DIR/all-authors.txt"

    is_pool_email() {
        local email_lc entry pool_email
        email_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
        for entry in "${ENGINEERS[@]}"; do
            pool_email=$(printf '%s' "${entry#*|}" | tr '[:upper:]' '[:lower:]')
            [ "$email_lc" = "$pool_email" ] && return 0
        done
        return 1
    }

    idx=0
    while IFS='|' read -r old_name old_email; do
        [ -z "$old_email" ] && continue
        if is_pool_email "$old_email"; then
            echo "  $old_name <$old_email> → (skipped, already in pool)"
            continue
        fi
        IFS='|' read -r new_name new_email <<< "${ENGINEERS[$idx]}"
        echo "$new_name <$new_email> $old_name <$old_email>" >> "$MAILMAP_FILE"
        echo "  $old_name <$old_email> → $new_name <$new_email>"
        idx=$(((idx + 1) % ${#ENGINEERS[@]}))
    done < "$WORK_DIR/all-authors.txt"

    if [ -s "$MAILMAP_FILE" ]; then
        FILTER_ARGS=(--mailmap "$MAILMAP_FILE")
    fi
fi

# --- Rewrite history ---
if [ ${#FILTER_ARGS[@]} -gt 0 ]; then
    echo "Rewriting history with git-filter-repo..."
    if ! git filter-repo --force --quiet "${FILTER_ARGS[@]}" > "$WORK_DIR/filter-repo.log" 2>&1; then
        cat "$WORK_DIR/filter-repo.log"
        exit 1
    fi
else
    echo "All authors already in the engineer pool — nothing to rewrite."
fi

echo "Authors after the rewrite:"
git log --branches --tags --format='   %an <%ae>' | sort | uniq -c | sort -rn

if [ "$PUSH" != 1 ]; then
    echo ""
    echo "✅ Done (local only). Rewritten mirror left at: $MIRROR"
    echo "Re-run with --push (or PUSH=1) to force-push to $TARGET_REPO"
    exit 0
fi

# --- Push ---
repo_path="${TARGET_REPO#git@github.com:}"
repo_path="${repo_path#https://github.com/}"
repo_path="${repo_path%.git}"

if [ -n "${TARGET_SSH_KEY:-}" ]; then
    TARGET_URL="git@github.com:${repo_path}.git"
    PUSH_GIT=(env GIT_SSH_COMMAND="$(ssh_with_key "$TARGET_SSH_KEY" target_key)" git)
else
    TARGET_URL="https://x-access-token:${GITHUB_PAT}@github.com/${repo_path}.git"
    PUSH_GIT=(git -c credential.helper= -c core.askPass=)
fi

echo ""
echo "Force-pushing all branches and tags to $repo_path..."
if ! "${PUSH_GIT[@]}" push --quiet --force "$TARGET_URL" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'; then
    echo "ERROR: Push failed. Check the key/token has write access to $repo_path, and its rulesets."
    exit 1
fi

cd /
rm -rf "$WORK_DIR"
echo "✅ Success! All commits rewritten and pushed to $repo_path."
