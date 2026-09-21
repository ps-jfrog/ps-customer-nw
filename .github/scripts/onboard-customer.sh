#!/usr/bin/env bash
#
# Onboard a customer engagement from an issue form. See
# docs/onboarding-issueops-proposal.md for why each step exists.
#
# Usage: onboard-customer.sh <issue-number> [onboard|rollback]
# Env:   GH_TOKEN     token for the template repo: reads the issue, writes the
#                     sticky comment, checks the actor's repository permission
#        APP_TOKEN    App installation token: creates and configures the
#                     repository and opens the Terraform PR. May be empty or
#                     under-permissioned; every step reports which.
#        ACTOR        github.actor
#        DRY_RUN      "true" validates and reports, writes nothing
#
# Every step is check-then-act and keyed on the slug, so re-running resumes
# rather than duplicating. Nothing here fails the job on a missing permission:
# a half-onboarded engagement that says exactly what it is beats a red X.

set -uo pipefail

ISSUE="${1:?usage: onboard-customer.sh <issue-number> [onboard|rollback]}"
COMMAND="${2:-onboard}"

ORG="${ORG:-ps-jfrog}"
TEMPLATE_REPO="${TEMPLATE_REPO:-ps-jfrog/ps-customer-template}"
TF_REPO="${TF_REPO:-ps-jfrog/acrois-tf-oidc-bootstrap}"
TF_VARS_FILE="${TF_VARS_FILE:-terraform.tfvars}"
DRY_RUN="${DRY_RUN:-false}"
ACTOR="${ACTOR:-}"
APP_TOKEN="${APP_TOKEN:-}"

# Pinned rather than defaulted. The workflow default of `latest` resolves
# `[RELEASE]` through ps-jf-prod-cli, which currently returns HTTP 500 from the
# platform; and the default remote name `jfrog-cli-remote` does not exist here.
JFROG_CLI_REMOTE="${JFROG_CLI_REMOTE:-ps-jf-prod-cli}"
JFROG_CLI_VERSION="${JFROG_CLI_VERSION:-2.102.0}"

# `BUNDLE_REPO` is derived from `JF_PROJECT` in the bundle workflow, and
# onboarding must never set `JF_PROJECT` (see the "no JF_PROJECT" step). A
# repository with neither computes an empty value and fails with
# "BUNDLE_REPO is empty", so it is set explicitly.
BUNDLE_REPO="${BUNDLE_REPO:-ps-jfrog-ps-bundles}"

# Required org custom property, `require_explicit_values: true`, allowed values
# Customer/Component/Solution/Document. Engagement repositories are Customer;
# the org default is Solution, which is why it has to be passed explicitly.
PS_DATA_CLASS="${PS_DATA_CLASS:-Customer}"

# Branch the seeded history lands on. The template's default branch.
SEED_BRANCH="${SEED_BRANCH:-main}"

: "${GH_TOKEN:?GH_TOKEN is required}"

MARKER="<!-- onboarding-state -->"
STATUS_ROWS=""
BLOCKERS=""
OVERALL="done"

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------
# done      the step's effect is in place (whether or not this run made it)
# skipped   deliberately not attempted
# blocked   cannot proceed without a human granting something
# failed    tried and errored
step() {
  local status="$1" name="$2" note="$3"
  STATUS_ROWS+="| ${status} | ${name} | ${note} |"$'\n'
  case "$status" in
  blocked)
    [ "$OVERALL" = "failed" ] || OVERALL="blocked"
    ;;
  failed) OVERALL="failed" ;;
  esac
  echo "[${status}] ${name} — ${note}"
}

blocker() {
  BLOCKERS+="${1}"$'\n'
}

icon() {
  case "$1" in
  done) echo ":white_check_mark:" ;;
  skipped) echo ":heavy_minus_sign:" ;;
  blocked) echo ":lock:" ;;
  *) echo ":x:" ;;
  esac
}

# --------------------------------------------------------------------------
# Read and parse the issue
# --------------------------------------------------------------------------
BODY="$(gh issue view "$ISSUE" --repo "$TEMPLATE_REPO" --json body --jq .body)"
ISSUE_AUTHOR="$(gh issue view "$ISSUE" --repo "$TEMPLATE_REPO" --json author --jq .author.login)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sticky() {
  local body="$1"
  local existing
  existing="$(gh api "/repos/${TEMPLATE_REPO}/issues/${ISSUE}/comments" --paginate \
    --jq "[.[] | select(.body | contains(\"${MARKER}\"))] | .[0].id // empty")"
  if [ -n "${existing:-}" ]; then
    gh api --method PATCH "/repos/${TEMPLATE_REPO}/issues/comments/${existing}" \
      -f body="$body" >/dev/null
  else
    gh api --method POST "/repos/${TEMPLATE_REPO}/issues/${ISSUE}/comments" \
      -f body="$body" >/dev/null
  fi
}

fail_early() {
  sticky "${MARKER}
## Onboarding could not start

$1

Fix the issue body or the permission above and comment \`/onboard\` to retry."
  gh issue edit "$ISSUE" --repo "$TEMPLATE_REPO" \
    --add-label "onboarding:failed" --remove-label "onboarding:in-progress" 2>/dev/null || true
  echo "::error::$1"
  exit 1
}

# --------------------------------------------------------------------------
# Authorise
# --------------------------------------------------------------------------
# The issue author is not the authoriser: anyone may file the request. Two
# checks, neither of which needs a permission the App does not already have.
#
# 1. Write access to this repository. GITHUB_TOKEN can read this about its own
#    repository, so it costs nothing and it is the same trust boundary that
#    already governs changing the automation.
# 2. Presence in CODEOWNERS for the onboarding paths. Deliberately an explicit
#    handle list rather than a team: resolving team membership needs the App to
#    hold organisation `Members: read`, which it does not, and adding a
#    permission to check a permission is the wrong trade.
authorize() {
  [ -n "$ACTOR" ] || fail_early "No actor to authorise."

  local perm
  perm="$(gh api "/repos/${TEMPLATE_REPO}/collaborators/${ACTOR}/permission" \
    --jq '.permission' 2>/dev/null || echo none)"
  case "$perm" in
  admin | maintain | write) ;;
  *) fail_early "\`@${ACTOR}\` has \`${perm}\` on \`${TEMPLATE_REPO}\`; onboarding needs \`write\` or better." ;;
  esac

  local owners="${SCRIPT_DIR}/../CODEOWNERS"
  if [ -f "$owners" ]; then
    if ! grep -v '^\s*#' "$owners" | grep -qi -- "@${ACTOR}\b"; then
      fail_early "\`@${ACTOR}\` is not listed in \`.github/CODEOWNERS\`. Onboarding writes to the JFrog platform; add the handle there first."
    fi
  fi
  echo "authorised: ${ACTOR} (${perm} on ${TEMPLATE_REPO})"
}

authorize

PARSED="$("$SCRIPT_DIR/parse-onboarding-issue.py" <<<"$BODY" 2>/tmp/onboard-errors)" || {
  fail_early "The issue form did not validate:

$(sed 's/^/  /' /tmp/onboard-errors)"
}
eval "$PARSED"

TARGET="${ORG}/${REPO_NAME}"
echo "target: ${TARGET} (slug=${SLUG}, visibility=${VISIBILITY}, runner=${RUNNER})"

gh issue edit "$ISSUE" --repo "$TEMPLATE_REPO" \
  --add-label "onboarding:in-progress" \
  --remove-label "onboarding:failed" 2>/dev/null || true

# --------------------------------------------------------------------------
# App token capability probe
# --------------------------------------------------------------------------
# Established once, up front, so each step reports "blocked" with the exact
# permission rather than a bare 403 from the middle of a run.
APP_OK=false
APP_REACH=""
if [ -n "$APP_TOKEN" ]; then
  if APP_REACH="$(GH_TOKEN="$APP_TOKEN" gh api /installation/repositories --paginate \
    --jq '.repositories[].full_name' 2>/dev/null)"; then
    APP_OK=true
  fi
fi

app_can_reach() {
  [ "$APP_OK" = "true" ] && grep -qx "$1" <<<"$APP_REACH"
}

# ==========================================================================
# rollback
# ==========================================================================
if [ "$COMMAND" = "rollback" ]; then
  # Deliberate, never automatic. A half-created repository may already contain
  # engagement work, and deleting that is not a decision automation gets to make.
  if ! gh repo view "$TARGET" --json name >/dev/null 2>&1; then
    step done "delete repository" "\`${TARGET}\` does not exist"
  else
    commits="$(gh api "/repos/${TARGET}/commits" --jq 'length' 2>/dev/null || echo 99)"
    branches="$(gh api "/repos/${TARGET}/branches" --jq 'length' 2>/dev/null || echo 99)"
    if [ "$commits" -gt 1 ] || [ "$branches" -gt 1 ]; then
      step skipped "delete repository" \
        "\`${TARGET}\` has ${commits} commit(s) on ${branches} branch(es) — more than the seed. Refusing to delete; do it by hand if you are sure."
    else
      step blocked "delete repository" \
        "the App has no \`Administration: write\`, so it cannot delete repositories. Delete \`${TARGET}\` by hand."
      blocker "Repository deletion needs **Repository permissions -> Administration: write** on the App."
    fi
  fi

  tf_pr="$(gh pr list --repo "$TF_REPO" --state open --search "ps-customer-${SLUG} in:title" \
    --json number --jq '.[0].number // empty' 2>/dev/null || true)"
  if [ -n "${tf_pr:-}" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      step skipped "close Terraform PR" "would close ${TF_REPO}#${tf_pr} (dry run)"
    elif GH_TOKEN="${APP_TOKEN:-$GH_TOKEN}" gh pr close "$tf_pr" --repo "$TF_REPO" >/dev/null 2>&1; then
      step done "close Terraform PR" "closed ${TF_REPO}#${tf_pr}"
    else
      step blocked "close Terraform PR" "cannot write to \`${TF_REPO}\`; close ${TF_REPO}#${tf_pr} by hand"
    fi
  else
    step done "close Terraform PR" "no open Terraform PR for \`${SLUG}\`"
  fi

  sticky "${MARKER}
## Rollback for \`${REPO_NAME}\`

| | step | detail |
| --- | --- | --- |
$(printf '%s' "$STATUS_ROWS" | while IFS='|' read -r _ s n d _; do
    printf '| %s | %s | %s |\n' "$(icon "${s// /}")" "$n" "$d"
  done)
"
  exit 0
fi

# ==========================================================================
# onboard
# ==========================================================================

# --- validate ------------------------------------------------------------
if gh repo view "$TARGET" --json name >/dev/null 2>&1; then
  REPO_EXISTS=true
  step done "validate" "\`${TARGET}\` already exists; continuing with configuration"
else
  REPO_EXISTS=false
  step done "validate" "slug \`${SLUG}\` is well-formed and \`${TARGET}\` is free"
fi

# --- create repository ---------------------------------------------------
# Deliberately NOT `POST /repos/{template}/generate`, for two independent
# reasons. Either one alone would be enough; do not "simplify" this back.
#
# 1. It cannot work in this organisation at all. `ps_data_class` is a required
#    org custom property with `require_explicit_values: true`, so every
#    /generate call fails with "Repository Property 'ps_data_class' requires an
#    explicit value to be set", and /generate has no parameter to supply one.
#    Granting the App organisation administration would not change this.
# 2. Even where it works, it produces a squashed `Initial commit` with **no
#    shared history** with the template. With no merge base, every later sync is
#    an unrelated-histories merge in which each file the template *modifies*
#    (rather than merely adds) is an add/add conflict, and the fan-out aborts.
#    `ps-customer-valero` was generated this way and syncs clean today only
#    because template changes since have happened to be additive; the first
#    modification to a shared file turns it into an aborting repository.
#
# `POST /orgs/{org}/repos` accepts `custom_properties`, and seeding by pushing
# the template's real history gives the new repository a merge base on day one.
# `ps-customer-bofa` was created that way and reports `up-to-date` against the
# template rather than merely "clean".
if [ "$REPO_EXISTS" = "true" ]; then
  step done "create repository" "[\`${TARGET}\`](https://github.com/${TARGET}) already exists — not touched"
elif [ "$DRY_RUN" = "true" ]; then
  step skipped "create repository" "would create \`${TARGET}\` via \`POST /orgs/${ORG}/repos\` with \`ps_data_class=${PS_DATA_CLASS}\`, then seed it with the template's history (dry run)"
else
  # Creating a repository in the org is an organisation-level write.
  # Repository-scoped permissions never satisfy it, no matter how many are
  # granted.
  if [ "$APP_OK" != "true" ]; then
    step blocked "create repository" "no usable App token"
    blocker "The App token could not be minted. Check \`vars.APP_CLIENT_ID\` and \`secrets.APP_PRIVATE_KEY\` on \`${TEMPLATE_REPO}\`."
  elif out="$(GH_TOKEN="$APP_TOKEN" gh api --method POST "/orgs/${ORG}/repos" \
    --input - <<<"$(jq -n \
      --arg name "$REPO_NAME" \
      --arg description "JFrog PS engagement — ${CUSTOMER_NAME}" \
      --argjson private "$([ "$VISIBILITY" = private ] && echo true || echo false)" \
      --arg data_class "$PS_DATA_CLASS" \
      '{
         name: $name,
         description: $description,
         private: $private,
         # An empty repository is the point: the seed step below pushes the
         # template history onto it, and auto_init would put an unrelated
         # root commit in the way of exactly the merge base we are buying.
         auto_init: false,
         custom_properties: { ps_data_class: [$data_class] }
       }')" 2>&1)"; then
    step done "create repository" "created [\`${TARGET}\`](https://github.com/${TARGET}) with \`ps_data_class=${PS_DATA_CLASS}\`"
    REPO_EXISTS=true
  else
    step blocked "create repository" "\`POST /orgs/${ORG}/repos\` was refused"
    blocker "Creating a repository needs **Organization permissions -> Administration: write** on the App, granted at <https://github.com/organizations/${ORG}/settings/apps/jfrog-ps-customer-template/permissions>, then accepted for the installation. Repository-scoped permissions cannot substitute for it."
    echo "::warning::${out}"
  fi
fi

# --- seed with the template's history -------------------------------------
# Check-then-act on commit count, so a re-run after a partial onboarding
# resumes instead of trying to push over engagement work. An empty repository
# answers 409 on /commits, which is the case we want to act on.
if [ "$REPO_EXISTS" != "true" ]; then
  step skipped "seed history" "no repository yet"
else
  seed_commits="$(GH_TOKEN="${APP_TOKEN:-$GH_TOKEN}" \
    gh api "/repos/${TARGET}/commits?per_page=1" --jq 'length' 2>/dev/null || echo 0)"
  if [ "${seed_commits:-0}" != "0" ]; then
    step done "seed history" "\`${TARGET}\` already has commits — not touched"
  elif [ "$DRY_RUN" = "true" ]; then
    step skipped "seed history" "would push the template's history to \`${TARGET}\` (dry run)"
  elif [ "$(git rev-list --count HEAD 2>/dev/null || echo 1)" -le 1 ]; then
    # A shallow checkout would push a single grafted commit — that is
    # /generate's failure mode wearing a different hat. The workflow asks for
    # fetch-depth: 0 precisely so this never silently degrades.
    step failed "seed history" "this checkout has no history to push; the workflow needs \`fetch-depth: 0\`"
  elif seed_out="$(git push --quiet \
    "https://x-access-token:${APP_TOKEN}@github.com/${TARGET}.git" \
    "HEAD:refs/heads/${SEED_BRANCH}" 2>&1)"; then
    step done "seed history" \
      "pushed $(git rev-list --count HEAD) commits of template history to \`${SEED_BRANCH}\`, so \`${TARGET}\` has a merge base with the template from day one"
  else
    step blocked "seed history" "cannot push to \`${TARGET}\`"
    blocker "Seeding needs **Repository permissions -> Contents: write** on the App for \`${TARGET}\`. A repository the App created is normally added to the installation automatically; if it was created by hand, add it at <https://github.com/organizations/${ORG}/settings/installations>."
    echo "::warning::${seed_out}"
  fi
fi

# --- repository settings -------------------------------------------------
if [ "$REPO_EXISTS" != "true" ]; then
  step skipped "repository settings" "no repository yet"
elif [ "$DRY_RUN" = "true" ]; then
  step skipped "repository settings" "would set visibility=${VISIBILITY}, delete_branch_on_merge (dry run)"
else
  # delete_branch_on_merge is not cosmetic here: without it a merged sync PR
  # leaves chore/sync-template behind, and the next fan-out has to lease
  # against a branch nobody owns.
  if GH_TOKEN="${APP_TOKEN:-$GH_TOKEN}" gh api --method PATCH "/repos/${TARGET}" \
    -F private="$([ "$VISIBILITY" = private ] && echo true || echo false)" \
    -F delete_branch_on_merge=true >/dev/null 2>&1; then
    step done "repository settings" "visibility \`${VISIBILITY}\`, \`delete_branch_on_merge\` on"
  else
    step blocked "repository settings" "cannot PATCH \`${TARGET}\`"
    blocker "Setting repository visibility and merge behaviour needs **Repository permissions -> Administration: write** on the App."
  fi
fi

# --- Actions variables ---------------------------------------------------
set_var() {
  GH_TOKEN="${APP_TOKEN:-$GH_TOKEN}" gh variable set "$1" --body "$2" --repo "$TARGET" >/dev/null 2>&1
}

if [ "$REPO_EXISTS" != "true" ]; then
  step skipped "repository variables" "no repository yet"
elif [ "$DRY_RUN" = "true" ]; then
  step skipped "repository variables" "would set JF_NAME, JFROG_CLI_REMOTE, JFROG_CLI_VERSION, BUNDLE_REPO, PREFERRED_RUNNER (dry run)"
else
  wanted=("JF_NAME=${JF_NAME}" "JFROG_CLI_REMOTE=${JFROG_CLI_REMOTE}"
    "JFROG_CLI_VERSION=${JFROG_CLI_VERSION}" "BUNDLE_REPO=${BUNDLE_REPO}")
  [ "$RUNNER" != "ubuntu-latest" ] && wanted+=("PREFERRED_RUNNER=${RUNNER}")

  ok=true
  for kv in "${wanted[@]}"; do
    set_var "${kv%%=*}" "${kv#*=}" || ok=false
  done

  if [ "$ok" = "true" ]; then
    step done "repository variables" "$(
      IFS=,
      echo "\`${wanted[*]}\`"
    )"
  else
    step blocked "repository variables" "cannot write Actions variables on \`${TARGET}\`"
    blocker "Setting repository variables needs **Repository permissions -> Variables: write** on the App. Until then set them by hand: $(
      IFS=' '
      echo "${wanted[*]}"
    )."
  fi

  # The trap this whole engagement was built around. Artifactory filters
  # candidate identity mappings by project_key *before* ordering by priority,
  # so a non-empty JF_PROJECT makes the per-repo priority-5 mapping ineligible
  # and the exchange falls through to the org-wide priority-8 Contributor,
  # which has no DELETE_OVERWRITE_REPOSITORY and a 60-second TTL. Asserting
  # absence is cheap; the failure it prevents is a 403 on republish and a
  # build-info step that expires mid-job.
  if GH_TOKEN="${APP_TOKEN:-$GH_TOKEN}" gh variable list --repo "$TARGET" 2>/dev/null |
    grep -q '^JF_PROJECT'; then
    step failed "no JF_PROJECT" "\`JF_PROJECT\` is set on \`${TARGET}\` — delete it, or every bundle token downgrades to a 60s Contributor"
  else
    step done "no JF_PROJECT" "confirmed unset, which is what keeps the per-repo bundle mapping eligible"
  fi
fi

# --- Terraform PR --------------------------------------------------------
TF_PR_URL=""
tf_entry="\"${TARGET}\","
# `.[0] | "\(.number) \(.url)"` renders "null null" for an empty list, which
# reads as a found PR. Select the field and let jq's `// empty` do the work.
existing_tf_pr="$(gh pr list --repo "$TF_REPO" --state open --search "ps-customer-${SLUG} in:title" \
  --json url --jq '.[0].url // empty' 2>/dev/null || true)"

if [ -n "${existing_tf_pr}" ]; then
  TF_PR_URL="${existing_tf_pr}"
  step done "Terraform PR" "already open: ${TF_PR_URL}"
elif [ "$DRY_RUN" = "true" ]; then
  step skipped "Terraform PR" "would add \`${tf_entry}\` to \`ps_engagement_repos\` in \`${TF_REPO}\` (dry run)"
elif ! app_can_reach "$TF_REPO"; then
  step blocked "Terraform PR" "the App is not installed on \`${TF_REPO}\`"
  blocker "Opening the Terraform PR needs the App installed on \`${TF_REPO}\`. Add it at <https://github.com/organizations/${ORG}/settings/installations> -> *JFrog PS Customer Template* -> **Repository access**. Until then, add \`${tf_entry}\` to \`ps_engagement_repos\` in \`${TF_VARS_FILE}\` by hand."
else
  work="$(mktemp -d)"
  branch="onboard/${REPO_NAME}"
  if GH_TOKEN="$APP_TOKEN" gh repo clone "$TF_REPO" "$work/tf" -- --depth 1 -q 2>/dev/null; then
    (
      cd "$work/tf" || exit 1
      git config user.name 'github-actions[bot]'
      git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
      git checkout -q -b "$branch"
      # Insert before the closing bracket of the list, preserving the comment
      # block that documents the scripts-general-util entry.
      python3 - "$TF_VARS_FILE" "$TARGET" <<'PY'
import re, sys
path, repo = sys.argv[1], sys.argv[2]
src = open(path).read()
if f'"{repo}"' in src:
    sys.exit(3)
m = re.search(r'(ps_engagement_repos\s*=\s*\[)(.*?)(\n\])', src, re.S)
if not m:
    sys.exit(4)
open(path, 'w').write(src[:m.end(2)] + f'\n  "{repo}",' + src[m.end(2):])
PY
      rc=$?
      [ $rc -eq 3 ] && exit 3
      [ $rc -ne 0 ] && exit 1
      git commit -qam "feat: provision ${TARGET}

Adds the engagement to ps_engagement_repos, which creates its group,
bundle permission, build-info permission, OIDC identity mapping and
shared-read membership."
      git push -q origin "$branch"
    )
    case $? in
    0)
      TF_PR_URL="$(GH_TOKEN="$APP_TOKEN" gh pr create --repo "$TF_REPO" \
        --title "feat: provision ${TARGET}" \
        --head "$branch" \
        --body "Adds \`${TARGET}\` to \`ps_engagement_repos\`, which is the whole change: the group, the bundle permission scoped to \`${SLUG}/**\`, the build-info permission, the OIDC identity mapping and shared-read membership all follow from it.

Requested in ${TEMPLATE_REPO}#${ISSUE}.

> [!IMPORTANT]
> Plan and apply with \`TF_VAR_plugin_project=ps-jf\`. Without it a dozen \`toset([])\` locals collapse and the plan proposes destroying around sixty resources.

Expected plan: **4 to add** (group, bundle permission, build-info permission, identity mapping) and **1 to change in place** (\`platform_permission.bundle_shared_read\` gaining the new group). Any destroy or replace means something is wrong — stop and investigate." 2>&1 | tail -n1)"
      step done "Terraform PR" "opened ${TF_PR_URL}"
      ;;
    3) step done "Terraform PR" "\`${TARGET}\` is already in \`ps_engagement_repos\`" ;;
    *)
      step failed "Terraform PR" "could not prepare the change in \`${TF_REPO}\`"
      ;;
    esac
  else
    step blocked "Terraform PR" "cannot clone \`${TF_REPO}\` with the App token"
    blocker "Opening the Terraform PR needs the App installed on \`${TF_REPO}\`."
  fi
  rm -rf "$work"
fi

# --- verification --------------------------------------------------------
# Deliberately not run here, and deliberately not reported as passing. The
# repository's JFrog steps cannot work until the Terraform PR merges and
# applies, because the identity mapping does not exist until then. A flow that
# ran them now would show a red X that means "waiting", which is the failure
# mode this whole document exists to avoid.
step skipped "verification" \
  "blocked on provisioning by design — run **Test OIDC to JFrog** and **Build JFrog PS Engagement Bundle** in \`${TARGET}\` once the Terraform PR has merged *and applied*"

# --------------------------------------------------------------------------
# Sticky comment
# --------------------------------------------------------------------------
TABLE="$(printf '%s' "$STATUS_ROWS" | while IFS='|' read -r _ s n d _; do
  printf '| %s | %s | %s |\n' "$(icon "$(echo "$s" | tr -d ' ')")" "$n" "$d"
done)"

case "$OVERALL" in
done) HEAD_LINE="## Onboarding \`${REPO_NAME}\` — automation complete" ;;
blocked) HEAD_LINE="## Onboarding \`${REPO_NAME}\` — waiting on a permission" ;;
*) HEAD_LINE="## Onboarding \`${REPO_NAME}\` — failed" ;;
esac

BODY_OUT="${MARKER}
${HEAD_LINE}

Requested by @${ISSUE_AUTHOR}, run by @${ACTOR}$([ "$DRY_RUN" = "true" ] && echo " (**dry run** — nothing was written)").

| | step | detail |
| --- | --- | --- |
${TABLE}"

if [ -n "$BLOCKERS" ]; then
  BODY_OUT+="
### Needs a human

$(printf '%s' "$BLOCKERS" | sed 's/^/- /')
"
fi

BODY_OUT+="
### What remains, always

0. **Add \`${TARGET}\` to \`.github/sync-targets.json\` in \`${TEMPLATE_REPO}\`.**
   Seeding with the template's history is what buys the merge base, but it also
   means the repository carries no \`template_repository\` marker — and that
   marker is how the fan-out discovers targets. Until it is listed under
   \`include\`, this repository is never synced.
1. **Review and merge the Terraform PR.** ${TF_PR_URL:-(not opened — see above)}
2. **Wait for it to apply.** The group, bundle permission, build-info
   permission and OIDC identity mapping do not exist until then, and nothing
   in \`${REPO_NAME}\` that talks to JFrog can pass before they do.
3. **Then verify**, in this order, because each step catches a different
   failure: publish the bundle; republish over the *same* path with different
   content (this is the one that proves the token carries
   \`DELETE_OVERWRITE_REPOSITORY\` rather than the fallthrough
   \`Contributor\` role); resolve \`scripts-general-util\`; publish build-info.

Comment \`/onboard\` to re-run — every step is check-then-act, so it resumes
rather than duplicating. Comment \`/onboard-rollback\` to undo an onboarding
that has not been used yet."

if [ "$DRY_RUN" != "true" ]; then
  sticky "$BODY_OUT"
  case "$OVERALL" in
  done) gh issue edit "$ISSUE" --repo "$TEMPLATE_REPO" --add-label "onboarding:done" --remove-label "onboarding:in-progress" 2>/dev/null || true ;;
  blocked) gh issue edit "$ISSUE" --repo "$TEMPLATE_REPO" --add-label "onboarding:blocked" --remove-label "onboarding:in-progress" 2>/dev/null || true ;;
  *) gh issue edit "$ISSUE" --repo "$TEMPLATE_REPO" --add-label "onboarding:failed" --remove-label "onboarding:in-progress" 2>/dev/null || true ;;
  esac
else
  echo "--- sticky comment (dry run) ---"
  printf '%s\n' "$BODY_OUT"
fi

{
  echo "$HEAD_LINE"
  echo
  echo "| | step | detail |"
  echo "| --- | --- | --- |"
  printf '%s\n' "$TABLE"
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

[ "$OVERALL" = "failed" ] && exit 1
exit 0
