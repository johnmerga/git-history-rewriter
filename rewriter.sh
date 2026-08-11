#!/bin/bash
set -e

# --- Configuration ---
SOURCE_REPO="git@github.com:Mereb-Tech/realgaming-store-api.git"
TARGET_REPO="git@github.com:johnmerga/test-api.git"
WORK_DIR="/tmp/git-rewrite-workdir-$(date +%s)"

# Rotating engineer pool
declare -a ENGINEERS=(
    "AA-Engineer-1|engineer1-a-1@teambase.click"
    "AA-Engineer-2|engineer2-a-1@teambase.click"
    "AA-Engineer-3|engineer3-a-1@teambase.click"
)

# Optional: Use PAT for HTTPS auth
# export GITHUB_PAT="ghp_xxxxxxxxxxxxxxxxxxxx"

# Push to TARGET_REPO? Off by default — rewrite locally and keep the result.
# Enable with:  PUSH=1 ./rewriter.sh    or    ./rewriter.sh --push
PUSH="${PUSH:-0}"

for arg in "$@"; do
    case "$arg" in
        --push) PUSH=1 ;;
        --no-push) PUSH=0 ;;
        -h|--help)
            echo "Usage: $0 [--push|--no-push]"
            echo "  Rewrites history locally by default; --push force-pushes to TARGET_REPO."
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$arg' (try --help)"
            exit 1
            ;;
    esac
done

case "$PUSH" in
    1|true|yes|on) PUSH=1 ;;
    *)             PUSH=0 ;;
esac

# --- Setup ---
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "Cloning source repo..."
git clone --mirror "$SOURCE_REPO" repo-mirror
cd repo-mirror

# --- Build rotating mailmap ---
# We assign authors round-robin based on original email hash for consistency
MAILMAP_FILE=".mailmap"
> "$MAILMAP_FILE"

# Extract unique authors from the repo
echo "Extracting unique authors..."
git log --all --format="%an|%ae" | sort -u > /tmp/all-authors.txt

ENGINEER_COUNT=${#ENGINEERS[@]}
idx=0

# True if the given email already belongs to the engineer pool
is_pool_email() {
    local email_lc
    email_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    local entry pool_email
    for entry in "${ENGINEERS[@]}"; do
        pool_email=$(printf '%s' "${entry#*|}" | tr '[:upper:]' '[:lower:]')
        [ "$email_lc" = "$pool_email" ] && return 0
    done
    return 1
}

while IFS='|' read -r old_name old_email; do
    # Skip empty lines
    [ -z "$old_email" ] && continue

    # Already one of our engineers — leave those commits untouched
    if is_pool_email "$old_email"; then
        echo "  $old_name <$old_email> → (skipped, already in pool)"
        continue
    fi

    # Assign engineer round-robin (deterministic based on order)
    IFS='|' read -r new_name new_email <<< "${ENGINEERS[$idx]}"

    echo "$new_name <$new_email> $old_name <$old_email>" >> "$MAILMAP_FILE"

    echo "  $old_name <$old_email> → $new_name <$new_email>"

    idx=$(((idx + 1) % ENGINEER_COUNT))
done < /tmp/all-authors.txt

echo ""
if [ -s "$MAILMAP_FILE" ]; then
    echo "Mailmap created:"
    cat "$MAILMAP_FILE"

    # --- Rewrite History ---
    if ! command -v git-filter-repo &> /dev/null; then
        echo "ERROR: git-filter-repo not found. Install it first:"
        echo "  pip install git-filter-repo    OR    brew install git-filter-repo"
        exit 1
    fi

    echo ""
    echo "Rewriting history with git-filter-repo..."
    git filter-repo --use-mailmap --force
else
    echo "All authors already in the engineer pool — nothing to rewrite."
fi

if [ "$PUSH" != "1" ]; then
    echo ""
    echo "✅ Done (local only). Rewritten mirror left at:"
    echo "     $WORK_DIR/repo-mirror"
    echo ""
    echo "Inspect it with:"
    echo "     git -C $WORK_DIR/repo-mirror log --all --format='%an <%ae>' | sort -u"
    echo ""
    echo "Re-run with --push (or PUSH=1) to force-push to $TARGET_REPO"
    exit 0
fi

# --- Configure Target Remote ---
if [ -n "$GITHUB_PAT" ]; then
    TARGET_REPO="https://${GITHUB_PAT}@github.com/johnmerga/test-api.git"
fi

git remote add target "$TARGET_REPO" 2>/dev/null || git remote set-url target "$TARGET_REPO"

# --- Push ---
echo ""
echo "Pushing to target repo..."
if ! git push target --all --force; then
    echo ""
    echo "ERROR: Push failed. Check repository rulesets or authentication."
    exit 1
fi

git push target --tags --force 2>/dev/null || echo "No tags to push"

# --- Cleanup ---
cd ..
rm -rf "$WORK_DIR"

echo ""
echo "✅ Success! All commits rewritten and pushed to target repo."
