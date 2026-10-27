#!/usr/bin/env bash
# Merge the upstream FlightScnr_Pi project into this repo on a staging branch.
#
# This script never touches the default branch. The workflow's publish job
# fast-forwards it only after the merged tree has been tested.
#
# Results are written as key=value lines to $GITHUB_OUTPUT (stdout when unset):
#   status             up_to_date | ready | conflict   (anything else fails the run)
#   base_sha           tip of the default branch before the merge
#   upstream_sha       upstream commit that was merged (status=ready)
#   sha                tip of the staging branch (status=ready)
#   conflicts          comma-separated conflicting paths (status=conflict)
#   held_back_workflows  upstream workflow changes that were NOT taken (status=ready)
#
# Upstream changes under .github/workflows/ are never merged. Our own workflows
# win, always: a pushed workflow change needs a privileged token, and letting
# upstream rewrite the CI that holds this repo's write token is not a trust
# relationship we want. Those changes are reported instead.
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/yashmulgaonkar/FlightScnr_Pi.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
BASE_BRANCH="${BASE_BRANCH:?BASE_BRANCH is required}"
STAGING_BRANCH="${STAGING_BRANCH:-sync/upstream}"
PUSH="${PUSH:-1}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

emit() { printf '%s=%s\n' "$1" "$2" >> "$OUT"; }

git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

git checkout -q "$BASE_BRANCH"
base_sha="$(git rev-parse HEAD)"
emit base_sha "$base_sha"

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
# --no-tags: upstream's release tags must not land in this repo, ours are
# created by the publish job and a collision would break the device updater.
git fetch -q --no-tags upstream "$UPSTREAM_BRANCH"
upstream_sha="$(git rev-parse "refs/remotes/upstream/$UPSTREAM_BRANCH")"

if git merge-base --is-ancestor "$upstream_sha" "$base_sha"; then
    echo "Already contains upstream ${upstream_sha:0:7}; nothing to do."
    emit status up_to_date
    exit 0
fi

git checkout -q -B "$STAGING_BRANCH" "$base_sha"

set +e
git merge --no-ff --no-commit "$upstream_sha" > /tmp/sync-merge.log 2>&1
merge_rc=$?
set -e
cat /tmp/sync-merge.log

mapfile -t unmerged < <(git diff --name-only --diff-filter=U)
blocking=()
for path in "${unmerged[@]}"; do
    case "$path" in
        .github/workflows/*) ;;
        *) blocking+=("$path") ;;
    esac
done

if (( ${#blocking[@]} > 0 )); then
    git merge --abort
    echo "Merge conflicts: ${blocking[*]}"
    emit status conflict
    emit conflicts "$(IFS=,; echo "${blocking[*]}")"
    exit 0
fi

if (( merge_rc != 0 && ${#unmerged[@]} == 0 )); then
    # Not a content conflict (e.g. unrelated histories): fail loudly.
    git merge --abort || true
    emit status error
    exit 1
fi

# Keep our workflows, whatever upstream did to theirs (see header).
held_back="$(git diff --cached --name-only HEAD -- .github/workflows | paste -sd, -)"
git rm -rq --cached --ignore-unmatch -- .github/workflows
rm -rf .github/workflows
git checkout HEAD -- .github/workflows

version="$(tr -d '[:space:]' < VERSION)"
git commit -q -m "Merge upstream FlightScnr_Pi ${version} (${upstream_sha:0:7})"

sha="$(git rev-parse HEAD)"
if [ "$PUSH" = "1" ]; then
    git push -q --force origin "$STAGING_BRANCH"
fi

echo "Staged ${sha:0:7} (upstream ${upstream_sha:0:7}, version ${version})."
emit status ready
emit sha "$sha"
emit upstream_sha "$upstream_sha"
emit held_back_workflows "$held_back"
