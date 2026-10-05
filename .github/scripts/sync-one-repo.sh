#!/usr/bin/env bash
#
# Sync one derived repository with the template, driven from the template.
#
# Usage: sync-one-repo.sh <owner/name>
# Env:   GH_TOKEN       installation token with contents/pull-requests/workflows
#                       write on the target
#        TEMPLATE_DIR   checkout of the template to sync FROM (default: cwd repo)
#        PR_BRANCH      bot branch in the target (default: chore/sync-template)
#        WORK_DIR       where the target gets cloned (default: mktemp -d)
#        DRY_RUN        "true" reports the outcome and writes nothing remote
#
# Writes `outcome=<value>` and `detail=<text>` to $GITHUB_OUTPUT when set.
# Outcomes: up-to-date | synced | no-changes | dry-run-clean
#           | aborted-conflict | aborted-foreign-branch | error
#
# Why this runs here and not in the target repository: minting a token requires
# the App's private key, and only the template holds one. Eight of the derived
# repositories have no credentials at all and therefore could never run their
# own sync. Inverting the direction — template pushes, target receives — is what
# removes the per-repo credential entirely. See docs/onboarding-issueops-proposal.md.
#
# Every safety property of the per-repo job is preserved by *reusing its
# scripts*, not by restating them: check-tree-sanity.sh still decides whether a
# tree may become a commit, and push-bot-branch.sh still owns the explicit lease
# and the refusal to discard human commits.

set -euo pipefail

TARGET="${1:?usage: sync-one-repo.sh <owner/name>}"
: "${GH_TOKEN:?GH_TOKEN is required}"

TEMPLATE_DIR="${TEMPLATE_DIR:-$(git rev-parse --show-toplevel)}"
TEMPLATE_DIR="$(cd "$TEMPLATE_DIR" && pwd)"
PR_BRANCH="${PR_BRANCH:-chore/sync-template}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
DRY_RUN="${DRY_RUN:-false}"
BOT_NAME="${BOT_NAME:-github-actions[bot]}"
BOT_EMAIL="${BOT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

TEMPLATE_SLUG="$(basename "$TEMPLATE_DIR")"
RETIRED_LIST="${TEMPLATE_DIR}/.github/sync-retired-paths.txt"

emit() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  # Outputs are single-line by contract; fold anything stray so a detail string
  # can never break out of the key=value form.
  printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" >>"$GITHUB_OUTPUT"
}

finish() {
  echo "::endgroup::"
  emit outcome "$1"
  emit detail "$2"
  echo "::notice title=${TARGET}::$1 — $2"
  # An abort is a correct, expected result for a repository that has not been
  # reconciled yet. Failing the job for it would make the fan-out red every
  # week for reasons nobody is going to act on this run, and would bury the
  # repositories that genuinely broke. The summary carries the distinction.
  exit 0
}

die() {
  echo "::endgroup::"
  emit outcome error
  emit detail "$1"
  echo "::error title=${TARGET}::$1"
  exit 1
}

echo "::group::${TARGET}"

# --------------------------------------------------------------------------
# Clone the target
# --------------------------------------------------------------------------
CLONE="${WORK_DIR}/${TARGET##*/}"
rm -rf "$CLONE"
if ! git clone --quiet --no-recurse-submodules \
  "https://x-access-token:${GH_TOKEN}@github.com/${TARGET}.git" "$CLONE"; then
  die "cannot clone ${TARGET} — the App is probably not installed on it"
fi
cd "$CLONE"

DEFAULT_BRANCH="$(git symbolic-ref --short HEAD)"
export DEFAULT_BRANCH GH_TOKEN BOT_EMAIL
export GITHUB_REPOSITORY="$TARGET"

git config user.name "$BOT_NAME"
git config user.email "$BOT_EMAIL"

# --------------------------------------------------------------------------
# Fetch the template tree
# --------------------------------------------------------------------------
# From the local checkout rather than over the network: it guarantees the tree
# being pushed is byte-for-byte the one this run validated, even if the
# template's default branch moves mid fan-out.
git remote add template "$TEMPLATE_DIR"
git fetch --quiet --no-tags template HEAD
TEMPLATE_SHA="$(git rev-parse FETCH_HEAD)"
echo "template ${TEMPLATE_SLUG}@${TEMPLATE_SHA:0:7} -> ${TARGET}@${DEFAULT_BRANCH}"

if git merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
  finish up-to-date "already contains template ${TEMPLATE_SHA:0:7}"
fi

# --------------------------------------------------------------------------
# Record the dependency model for the abort message
# --------------------------------------------------------------------------
submodule_era=false
if [ -n "$(git ls-files -s -- scripts-general-util | awk '$1 == "160000" {print $4}')" ]; then
  submodule_era=true
elif [ -f .gitmodules ] &&
  git config -f .gitmodules --get submodule.scripts-general-util.path >/dev/null 2>&1; then
  submodule_era=true
fi

# --------------------------------------------------------------------------
# Merge
# --------------------------------------------------------------------------
git checkout --quiet -B "$PR_BRANCH" "origin/${DEFAULT_BRANCH}"

conflicts=false
content_conflicts=""
submodule_conflicts=""

if ! git merge FETCH_HEAD --no-commit --no-ff --allow-unrelated-histories >/dev/null 2>&1; then
  unmerged="$(git ls-files --unmerged)"
  submodule_conflicts="$(echo "$unmerged" | awk '$1 == "160000" {print $4}' | sort -u)"
  content_conflicts="$(echo "$unmerged" | awk '$1 != "160000" {print $4}' | sort -u)"

  # Gitlinks have no checked-out commit here (clone is --no-recurse-submodules),
  # so `git add` would refuse them. Write the template's side straight into the
  # index, or drop the entry when the template no longer declares it.
  if [ -n "$submodule_conflicts" ]; then
    while IFS= read -r submod; do
      [ -n "$submod" ] || continue
      their_sha="$(echo "$unmerged" |
        awk -v p="$submod" '$1 == "160000" && $3 == 3 && $4 == p {print $2}' | head -n1)"
      if [ -n "$their_sha" ]; then
        git update-index --cacheinfo "160000,${their_sha},${submod}"
      else
        git rm --cached -- "$submod" >/dev/null 2>&1 || true
      fi
    done <<<"$submodule_conflicts"
  fi

  [ -n "$content_conflicts" ] && conflicts=true

  git add -A

  remaining="$(git ls-files --unmerged | awk '{print $4}' | sort -u)"
  if [ -n "$remaining" ]; then
    echo "::warning::${TARGET}: deletion conflicts resolved by removing: ${remaining//$'\n'/, }"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      git rm -f -- "$path" >/dev/null 2>&1 || true
    done <<<"$remaining"
  fi
fi

# --------------------------------------------------------------------------
# Retired paths
# --------------------------------------------------------------------------
# A file the template deletes does not disappear from a repository whose
# history is unrelated to it: with no merge base, "absent on one side" reads as
# "added by the other", so the target keeps it forever. Retirements therefore
# have to be applied, not merged. Listing them in a reviewed file — rather than
# inferring "not in the template, so delete it" — keeps the fan-out from
# reaching for anything a repository legitimately owns.
retired_applied=""
if [ -f "$RETIRED_LIST" ]; then
  while IFS= read -r path; do
    case "$path" in '' | '#'*) continue ;; esac
    if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      git rm -q -f -- "$path"
      retired_applied+="${path}"$'\n'
    fi
  done <"$RETIRED_LIST"
fi

# --------------------------------------------------------------------------
# Guard: the tree must be sane before it can become a commit
# --------------------------------------------------------------------------
if ! "${TEMPLATE_DIR}/.github/scripts/check-tree-sanity.sh"; then
  if [ "$submodule_era" = "true" ]; then
    finish aborted-conflict \
      "tree is not safe to commit; repo is still on the git-submodule model and needs Migrate From Submodules first"
  fi
  finish aborted-conflict \
    "tree is not safe to commit (conflict markers or unparseable shell/YAML); reconcile ${PR_BRANCH} by hand"
fi

if ! git rev-parse -q --verify MERGE_HEAD >/dev/null && git diff --cached --quiet; then
  finish no-changes "merge produced no changes"
fi

if [ "$DRY_RUN" = "true" ]; then
  changed="$(git diff --cached --name-only | wc -l | tr -d ' ')"
  finish dry-run-clean "would open a PR touching ${changed} path(s) at template ${TEMPLATE_SHA:0:7}"
fi

# --------------------------------------------------------------------------
# Commit and push
# --------------------------------------------------------------------------
COMMIT_MSG="chore: sync with template (${TEMPLATE_SHA:0:7})"
[ "$conflicts" = "true" ] && COMMIT_MSG="${COMMIT_MSG} [auto-resolved]"
git commit --quiet --no-edit -m "$COMMIT_MSG"

if ! "${TEMPLATE_DIR}/.github/scripts/push-bot-branch.sh" "$PR_BRANCH"; then
  finish aborted-foreign-branch \
    "${PR_BRANCH} carries commits this bot did not make; review and merge or delete it"
fi

# --------------------------------------------------------------------------
# Open or refresh the PR
# --------------------------------------------------------------------------
BODY="Syncs this repository with the upstream template
[\`${TEMPLATE_SLUG}\`](https://github.com/${TARGET%%/*}/${TEMPLATE_SLUG}) at \`${TEMPLATE_SHA:0:7}\`.

Opened by the template's **Fan-out Template Sync**, which holds the only App
credential — this repository needs none of its own.

The merged tree was checked before it was committed: no conflict markers, and
every \`.envrc\`/\`.envrc.d\` shell file and workflow YAML parses."

if [ -n "$retired_applied" ]; then
  BODY="${BODY}

> [!NOTE]
> **Removed because the template retired it:**
>
$(printf '%s' "$retired_applied" | sed 's/^/> - `/; s/$/`/')
>
> A retired path cannot arrive through the merge itself, so the sync deletes it
> explicitly."
fi

if [ "$conflicts" = "true" ]; then
  BODY="${BODY}

> [!WARNING]
> **These paths were unmerged and resolved automatically:**
>
$(printf '%s' "$content_conflicts" | sed 's/^/> - `/; s/$/`/')
>
> Read the diff for them before merging."
fi

if [ -n "$submodule_conflicts" ]; then
  BODY="${BODY}

> [!NOTE]
> **Submodule pointers set to the template's revision** (or dropped where the
> template no longer declares them):
>
$(printf '%s' "$submodule_conflicts" | sed 's/^/> - `/; s/$/`/')"
fi

existing="$(gh pr list --repo "$TARGET" --head "$PR_BRANCH" --state open \
  --json number --jq '.[0].number // empty')"

if [ -n "${existing:-}" ]; then
  gh pr edit "$existing" --repo "$TARGET" --body "$BODY" >/dev/null
  finish synced "updated PR #${existing}"
fi

url="$(gh pr create --repo "$TARGET" \
  --title "chore: sync with upstream template" \
  --body "$BODY" \
  --base "$DEFAULT_BRANCH" \
  --head "$PR_BRANCH" 2>&1 | tail -n1)"

finish synced "$url"
