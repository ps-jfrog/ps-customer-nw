#!/usr/bin/env bash
#
# Push a regenerated bot branch, repeatably, without clobbering a human.
#
# Usage: push-bot-branch.sh <branch>
# Env:   GH_TOKEN            token with contents:write on GITHUB_REPOSITORY
#        GITHUB_REPOSITORY   owner/name
#        DEFAULT_BRANCH      branch the bot branch is cut from
#        BOT_EMAIL           identity the bot commits under
#        PUSH_URL            override the derived remote URL (tests)
#
# Why not a plain `git push --force-with-lease`: the checkout runs with
# persist-credentials:false, so the push target is a one-off authenticated URL
# rather than a configured remote. A bare lease is computed from the
# remote-tracking ref for the branch, and a URL that is not a remote has none -
# so git rejects every push after the first with "stale info", which is exactly
# how the sync branch latched shut once it existed. This reads the remote tip
# explicitly and leases against that oid instead, which needs no tracking ref
# and is still a real lease: a tip that moved between the read and the push
# fails the update rather than overwriting it.

set -euo pipefail

BRANCH="${1:?usage: push-bot-branch.sh <branch>}"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}"
BOT_EMAIL="${BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

PUSH_URL="${PUSH_URL:-}"
if [ -z "$PUSH_URL" ]; then
  : "${GH_TOKEN:?GH_TOKEN is required}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  PUSH_URL="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi
PEEK_REF="refs/ps-bot/${BRANCH}"

remote_sha=$(git ls-remote --heads "$PUSH_URL" "refs/heads/${BRANCH}" | awk 'NR==1 {print $1}')

if [ -z "$remote_sha" ]; then
  # The branch is absent: either it has never existed, or the repository has
  # delete_branch_on_merge and the last sync PR was merged. An empty lease
  # value means "the ref must not exist", so a concurrent creator loses the
  # race instead of being overwritten.
  echo "Branch ${BRANCH} does not exist on the remote; creating it."
  git push --force-with-lease="refs/heads/${BRANCH}:" \
    "$PUSH_URL" "HEAD:refs/heads/${BRANCH}"
  exit 0
fi

echo "Branch ${BRANCH} exists at ${remote_sha}; checking who owns it."
git fetch --no-tags --force "$PUSH_URL" "+refs/heads/${BRANCH}:${PEEK_REF}"

base="refs/remotes/origin/${DEFAULT_BRANCH}"
git rev-parse -q --verify "$base" >/dev/null || base="$DEFAULT_BRANCH"
git rev-parse -q --verify "$base" >/dev/null || {
  echo "ERROR: cannot resolve default branch '${DEFAULT_BRANCH}' locally." >&2
  exit 1
}

# Only the branch's own commits matter. Walking --first-parent from its tip
# skips everything the merge dragged in from the template - those are authored
# by whoever wrote the template commit and would otherwise all look foreign -
# and leaves exactly the commits made on this branch: the bot's merge commits,
# plus anything a human pushed or merged on top.
foreign=$(git log --first-parent --format='%H%x09%an <%ae>%x09%cn <%ce>' \
  "${base}..${PEEK_REF}" |
  awk -F'\t' -v bot="$BOT_EMAIL" '
    function is_bot(ident) {
      return index(ident, "<" bot ">") > 0 || ident ~ /\[bot\]@[^>]*>$/
    }
    !is_bot($2) || !is_bot($3) { print }
  ' || true)

git update-ref -d "$PEEK_REF" || true

if [ -n "$foreign" ]; then
  cat >&2 <<MSG
ERROR: ${BRANCH} carries commits that this bot did not make:

$(printf '%s\n' "$foreign" | sed 's/^/  /')

Force-updating the branch would discard them. Review and merge (or close and
delete) the branch, then re-run - the next run recreates it from scratch.
MSG
  exit 1
fi

# Real lease against the oid just read, so a push racing this one still fails
# closed. Safe to repeat: every run re-reads the tip.
git push --force-with-lease="refs/heads/${BRANCH}:${remote_sha}" \
  "$PUSH_URL" "HEAD:refs/heads/${BRANCH}"
