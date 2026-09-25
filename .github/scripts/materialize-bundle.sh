#!/usr/bin/env bash
#
# Materialize one published version of a customer's Artifactory PS bundle as
# a git commit on an orphan "mirror" branch in that customer's own repo. The
# branch's tree is nothing but the bundle's exploded content — that's what
# lets subtree-sync.sh treat it as an ordinary remote to subtree add/pull/push
# against from the customer's default branch.
#
# Run from inside an already-cloned checkout of the target repository, with
# JFrog CLI already configured under $JFROG_CLI_SERVER_ID (read access to
# $BUNDLE_REPO is enough — this only ever downloads).
#
# Usage: materialize-bundle.sh
# Env:   JFROG_CLI_SERVER_ID  jf CLI server id to read the bundle with
#        BUNDLE_REPO          generic repo holding bundles, e.g. ps-jfrog-ps-bundles
#        BUNDLE_NAME          bundle name, e.g. <repo-name> with jfrog-cli-plugin- stripped
#        BUNDLE_VERSION       published version to mirror, e.g. v2026.19.02.5
#        MIRROR_BRANCH        branch to commit onto (default: bundle-mirror)
#        DEFAULT_BRANCH       the repo's default branch, passed to push-bot-branch.sh
#        GH_TOKEN             token with contents:write on the target repo
#        GITHUB_REPOSITORY    owner/name of the target repo
#        BOT_NAME/BOT_EMAIL   commit identity (defaults match the rest of the fleet)
#        DRY_RUN              "true" reports the plan and writes nothing
#
# Writes `outcome=<value>` and `detail=<text>` to $GITHUB_OUTPUT when set.
# Outcomes: mirrored | up-to-date | dry-run-clean | error

set -uo pipefail

: "${JFROG_CLI_SERVER_ID:?JFROG_CLI_SERVER_ID is required}"
: "${BUNDLE_REPO:?BUNDLE_REPO is required}"
: "${BUNDLE_NAME:?BUNDLE_NAME is required}"
: "${BUNDLE_VERSION:?BUNDLE_VERSION is required}"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}"
MIRROR_BRANCH="${MIRROR_BRANCH:-bundle-mirror}"
BOT_NAME="${BOT_NAME:-github-actions[bot]}"
BOT_EMAIL="${BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
DRY_RUN="${DRY_RUN:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FOLDER_PATH="${BUNDLE_REPO}/${BUNDLE_NAME}/${BUNDLE_VERSION}"

emit() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" >>"$GITHUB_OUTPUT"
}

finish() {
  emit outcome "$1"
  emit detail "$2"
  echo "[$1] $2"
  exit 0
}

die() {
  emit outcome error
  emit detail "$1"
  echo "::error::$1" >&2
  exit 1
}

cd "$(git rev-parse --show-toplevel)"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty; refusing to mirror onto ${MIRROR_BRANCH}"

# --------------------------------------------------------------------------
# Verify the bundle version exists and is non-empty before touching any branch
# --------------------------------------------------------------------------
# RUNNER_TEMP, not /tmp: self-hosted runners keep /tmp between jobs, so a
# fixed shared path collects a stale response from a concurrent matrix leg.
STORAGE_JSON="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/materialize-storage.XXXXXX")"
STATUS=$(jf rt curl --server-id="$JFROG_CLI_SERVER_ID" \
  -s -o "$STORAGE_JSON" -w '%{http_code}' \
  -X GET "api/storage/${FOLDER_PATH}")
[ "$STATUS" = "200" ] || die "bundle folder not found at ${FOLDER_PATH} (HTTP ${STATUS})"
jq -e '.children | length > 0' "$STORAGE_JSON" >/dev/null ||
  die "bundle folder ${FOLDER_PATH} exists but is empty"
rm -f "$STORAGE_JSON"

if [ "$DRY_RUN" = "true" ]; then
  finish dry-run-clean "would mirror ${FOLDER_PATH} onto ${MIRROR_BRANCH} (dry run)"
fi

# --------------------------------------------------------------------------
# Checkout (or create) the orphan mirror branch
# --------------------------------------------------------------------------
ORIGINAL_REF="$(git symbolic-ref --short -q HEAD || git rev-parse HEAD)"
if git ls-remote --exit-code --heads origin "$MIRROR_BRANCH" >/dev/null 2>&1; then
  git fetch --quiet origin "$MIRROR_BRANCH:refs/remotes/origin/${MIRROR_BRANCH}" --force
  git checkout --quiet -B "$MIRROR_BRANCH" "origin/${MIRROR_BRANCH}"
else
  git checkout --quiet --orphan "$MIRROR_BRANCH"
  git rm -rf --quiet . >/dev/null 2>&1 || true
fi

cleanup() {
  git checkout --quiet "$ORIGINAL_REF" 2>/dev/null || true
}
trap cleanup EXIT

# Clear the branch's tree before repopulating it, so a version that dropped
# files does not leave the old ones behind — this branch has no content of
# its own to preserve, only successive bundle snapshots.
find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

DL_DIR="$(mktemp -d)"
jf rt dl --server-id="$JFROG_CLI_SERVER_ID" --flat=false --quiet \
  "${FOLDER_PATH}/*" "${DL_DIR}/" || die "download of ${FOLDER_PATH} failed"

# jf rt dl --flat=false preserves the source path with the repository name
# stripped, so the bundle's own files land under DL_DIR/<BUNDLE_NAME>/<VERSION>.
# Locating it by that suffix rather than assuming DL_DIR's exact shape keeps
# this working even if the CLI's flattening convention changes.
BUNDLE_ROOT="$(find "$DL_DIR" -type d -path "*/${BUNDLE_NAME}/${BUNDLE_VERSION}" | head -n1)"
[ -n "$BUNDLE_ROOT" ] || die "downloaded tree has no ${BUNDLE_NAME}/${BUNDLE_VERSION} directory"
[ -n "$(find "$BUNDLE_ROOT" -type f | head -n1)" ] || die "downloaded ${FOLDER_PATH} produced no files"

# Copy rather than move: leaves DL_DIR intact for debugging on failure, and
# cp -a preserves whatever permissions the bundle files carry.
cp -a "${BUNDLE_ROOT}/." .
rm -rf "$DL_DIR"

git add -A

if git diff --cached --quiet; then
  finish up-to-date "${MIRROR_BRANCH} already matches ${FOLDER_PATH}"
fi

git config user.name "$BOT_NAME"
git config user.email "$BOT_EMAIL"
git commit --quiet -m "chore: mirror bundle ${BUNDLE_NAME} ${BUNDLE_VERSION}"

DEFAULT_BRANCH="$DEFAULT_BRANCH" BOT_EMAIL="$BOT_EMAIL" \
  "${SCRIPT_DIR}/push-bot-branch.sh" "$MIRROR_BRANCH" ||
  die "push-bot-branch.sh refused to push ${MIRROR_BRANCH} — see its output above"

finish mirrored "committed and pushed ${BUNDLE_NAME} ${BUNDLE_VERSION} onto ${MIRROR_BRANCH}"
