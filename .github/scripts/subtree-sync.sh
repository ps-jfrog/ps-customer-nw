#!/usr/bin/env bash
#
# Bidirectionally sync a subdirectory of this repo with a remote repo that
# shares no history with it - e.g. a customer's own fork of the same folder
# that was never actually forked from us. Uses `git subtree`, which merges
# by content rather than common ancestry, so unrelated histories are not a
# problem.
#
# This repo is the source of truth. Pull brings in whatever changed on the
# other side; push sends this repo's current state of the folder back out.
# Run it from wherever has the credentials for --remote - a PS laptop, or
# the customer's own machine syncing against this repo as --remote.
#
# Usage: subtree-sync.sh --prefix <path> --remote <url-or-name> [options]
#   --prefix <path>      subdirectory of this repo to sync (required)
#   --remote <url|name>  the other repo: a URL, or an already-configured
#                        git remote name (required)
#   --branch <branch>    branch on the other side to sync against (default: main)
#   --pull-only          only bring their changes in, do not push ours out
#   --push-only          only send our changes out, do not pull theirs in
#   --push-origin        after a clean sync, also push this branch to 'origin'
#                        (off by default - review the merge first)
#   --dry-run            print what would run, change nothing
#
# First run against a --prefix that doesn't exist yet does `git subtree add`
# instead of pull, bootstrapping the folder from the other side.
#
# A conflicting pull stops the script with the tree left mid-merge, same as
# any git merge: resolve it, `git add` the result, `git commit`, then re-run
# to push. Nothing is pushed anywhere - not even to the other side, let
# alone origin - until the tree is clean, so a bad periodic run never
# clobbers either remote.

set -euo pipefail

PREFIX=""
REMOTE=""
BRANCH="main"
PULL_ONLY=0
PUSH_ONLY=0
PUSH_ORIGIN=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --pull-only) PULL_ONLY=1; shift ;;
    --push-only) PUSH_ONLY=1; shift ;;
    --push-origin) PUSH_ORIGIN=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

: "${PREFIX:?--prefix is required}"
: "${REMOTE:?--remote is required}"
if [ "$PULL_ONLY" -eq 1 ] && [ "$PUSH_ONLY" -eq 1 ]; then
  echo "--pull-only and --push-only are mutually exclusive" >&2
  exit 2
fi

# `git subtree --help` exits non-zero even when installed, on systems
# without its man page (it falls through to `man` and that fails) - checking
# stdout for git's own "not a git command" message is what actually detects
# absence, not the exit code.
if git subtree 2>&1 | grep -q "is not a git command"; then
  echo "ERROR: git subtree is required (ships with git-extras / the git-contrib" >&2
  echo "package on most distros; Homebrew's git includes it already)." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is dirty. Commit or stash first - a subtree merge" >&2
  echo "needs a clean base to tell your edits apart from theirs." >&2
  exit 1
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would run: $*"
    return 0
  fi
  echo "+ $*"
  "$@"
}

# A URL (vs. an existing remote name) gets a stable local name derived from
# the prefix, so repeated runs reuse one remote instead of piling up
# anonymous fetches or re-adding it every time.
REMOTE_NAME="$REMOTE"
if [[ "$REMOTE" == *://* || "$REMOTE" == *@*:* ]]; then
  REMOTE_NAME="subtree-$(basename "$PREFIX")"
  if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    current_url="$(git remote get-url "$REMOTE_NAME")"
    if [ "$current_url" != "$REMOTE" ]; then
      echo "ERROR: remote '${REMOTE_NAME}' already points at ${current_url}, not ${REMOTE}." >&2
      echo "Pass --remote ${REMOTE_NAME} to reuse it, or 'git remote remove ${REMOTE_NAME}' first." >&2
      exit 1
    fi
  else
    run git remote add "$REMOTE_NAME" "$REMOTE"
  fi
fi

run git fetch "$REMOTE_NAME" "$BRANCH"

if [ "$PUSH_ONLY" -ne 1 ]; then
  if [ -d "$PREFIX" ]; then
    echo "Pulling ${REMOTE_NAME}/${BRANCH} into ${PREFIX} (squashed - unrelated history)..."
    if ! run git subtree pull --prefix="$PREFIX" "$REMOTE_NAME" "$BRANCH" --squash \
      -m "chore: sync ${PREFIX} from ${REMOTE_NAME}/${BRANCH}"; then
      echo "" >&2
      echo "Conflict merging ${REMOTE_NAME}/${BRANCH} into ${PREFIX}." >&2
      echo "Resolve it, 'git add' the result, 'git commit', then re-run to push." >&2
      exit 1
    fi
  else
    echo "${PREFIX} does not exist yet; bootstrapping from ${REMOTE_NAME}/${BRANCH}..."
    run git subtree add --prefix="$PREFIX" "$REMOTE_NAME" "$BRANCH" --squash
  fi
fi

if [ "$PULL_ONLY" -ne 1 ]; then
  echo "Pushing ${PREFIX} back to ${REMOTE_NAME}/${BRANCH}..."
  run git subtree push --prefix="$PREFIX" "$REMOTE_NAME" "$BRANCH"

  # A push moves the remote without creating a local squash commit, so the
  # next pull's --squash merge-base is still the last commit *pull* made -
  # now stale. Left alone, a later genuinely-clean pull (their next edit,
  # appended after content this push already carried over) 3-way-merges
  # against that stale base and conflicts on lines neither side actually
  # touched independently. Re-pulling immediately - a no-op, since the
  # remote now matches us - re-anchors the bookkeeping so future pulls
  # compute the right base. Verified empirically; this isn't documented
  # behavior of `git subtree`, just how its squash tracking falls out.
  if [ "$DRY_RUN" -ne 1 ]; then
    run git fetch "$REMOTE_NAME" "$BRANCH"
    if ! run git subtree pull --prefix="$PREFIX" "$REMOTE_NAME" "$BRANCH" --squash \
      -m "chore: checkpoint ${PREFIX} sync bookkeeping after push"; then
      echo "" >&2
      echo "Checkpoint pull after push conflicted - something changed on" >&2
      echo "${REMOTE_NAME}/${BRANCH} in the window between push and this pull." >&2
      echo "Resolve it, 'git add' the result, 'git commit', then re-run." >&2
      exit 1
    fi
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  exit 0
fi

if [ "$PUSH_ORIGIN" -eq 1 ]; then
  run git push origin "$(git rev-parse --abbrev-ref HEAD)"
else
  echo ""
  echo "Sync complete locally. Review it - 'git log --oneline -5', 'git diff HEAD@{1} -- ${PREFIX}' -"
  echo "then 'git push origin $(git rev-parse --abbrev-ref HEAD)' when you're happy with it."
fi
