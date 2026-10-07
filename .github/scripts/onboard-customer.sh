#!/usr/bin/env bash
#
# Onboard a customer engagement from an issue form. See
# docs/onboarding-issueops-proposal.md for why each step exists.
#
# Usage: onboard-customer.sh <issue-number> [onboard|rollback|verify|offboard|offboard-finish]
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

# Generated repositories land on the template's default branch. Nothing in
# this script pushes history onto that branch.
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

parse_mode=onboard
case "$COMMAND" in
offboard | offboard-finish) parse_mode=offboard ;;
esac
PARSED="$("$SCRIPT_DIR/parse-onboarding-issue.py" "$parse_mode" <<<"$BODY" 2>/tmp/onboard-errors)" || {
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

# terraform.tfvars is git-crypt ciphertext. The template App must not clone
# the bootstrap repo and edit it. Membership changes are a workflow_dispatch
# in that repo, which unlocks, plans, and opens the pull request itself.
dispatch_membership() {
  local action="$1"
  local manual="gh workflow run engagement-membership.yaml --repo ${TF_REPO} -f action=${action} -f repository=${TARGET}"
  if [ "$DRY_RUN" = "true" ]; then
    step skipped "membership" "would dispatch \`${action}\` for \`${TARGET}\` (dry run). Otherwise: \`${manual}\`"
    return 0
  fi
  if [ "$APP_OK" != "true" ] || ! app_can_reach "$TF_REPO"; then
    step blocked "membership" "the App cannot reach \`${TF_REPO}\`. Run \`${manual}\`"
    blocker "Install the App on \`${TF_REPO}\` and grant **Actions: write** at <https://github.com/organizations/${ORG}/settings/installations/127861359>, then run \`${manual}\`."
    return 1
  fi
  local err
  if err="$(GH_TOKEN="$APP_TOKEN" gh api --method POST \
    "/repos/${TF_REPO}/actions/workflows/engagement-membership.yaml/dispatches" \
    --input - <<<"$(jq -n --arg action "$action" --arg repository "$TARGET" \
      '{ref:"main", inputs:{action:$action, repository:$repository}}')" 2>&1)"; then
    step done "membership" "dispatched \`${action}\` for \`${TARGET}\` on \`${TF_REPO}\`. A human merges that pull request and applies it on acrois with \`TF_VAR_plugin_project=ps-jf\`."
    return 0
  fi
  step blocked "membership" "could not dispatch \`${action}\`. Run \`${manual}\`"
  blocker "Dispatch needs **Actions: write** on the App for \`${TF_REPO}\` (<https://github.com/organizations/${ORG}/settings/installations/127861359>). ${err}"
  return 1
}

# A merged add/provision pull request, with no later merged removal, is the
# signal that this slug was applied. The template cannot read git-crypt state.
membership_was_applied() {
  local titles
  titles="$(gh pr list --repo "$TF_REPO" --state merged --limit 50 --search "${TARGET} in:title" \
    --json title --jq '.[].title' 2>/dev/null || true)"
  if grep -q "remove ${TARGET}" <<<"$titles"; then
    return 1
  fi
  grep -q -e "add ${TARGET}" -e "provision ${TARGET}" <<<"$titles"
}

close_membership_pr() {
  local branch="$1"
  local number
  number="$(gh pr list --repo "$TF_REPO" --state open --head "$branch" \
    --json number --jq '.[0].number // empty' 2>/dev/null || true)"
  if [ -z "${number:-}" ]; then
    step done "close membership PR" "no open \`${branch}\` pull request"
    return 0
  fi
  if [ "$DRY_RUN" = "true" ]; then
    step skipped "close membership PR" "would close ${TF_REPO}#${number} (dry run)"
    return 0
  fi
  if GH_TOKEN="${APP_TOKEN:-$GH_TOKEN}" gh pr close "$number" --repo "$TF_REPO" >/dev/null 2>&1; then
    step done "close membership PR" "closed ${TF_REPO}#${number}"
  else
    step blocked "close membership PR" "cannot write to \`${TF_REPO}\`; close ${TF_REPO}#${number} by hand"
  fi
}

# headline, label to add, close reason (empty leaves the issue open), footer,
# then labels to remove.
finish() {
  local headline="$1" add_label="$2" close_reason="$3" footer="$4"
  shift 4
  local table
  table="$(printf '%s' "$STATUS_ROWS" | while IFS='|' read -r _ s n d _; do
    printf '| %s | %s | %s |\n' "$(icon "$(echo "$s" | tr -d ' ')")" "$n" "$d"
  done)"

  local body_out="${MARKER}
${headline}

Requested by @${ISSUE_AUTHOR}, run by @${ACTOR}$([ "$DRY_RUN" = "true" ] && echo " (**dry run** — nothing was written)").

| | step | detail |
| --- | --- | --- |
${table}"

  if [ -n "$BLOCKERS" ]; then
    body_out+="
### Needs a human

$(printf '%s' "$BLOCKERS" | sed 's/^/- /')
"
  fi
  body_out+="
${footer}"

  if [ "$DRY_RUN" != "true" ]; then
    sticky "$body_out"
    local edit_args=()
    if [ -n "$add_label" ]; then
      edit_args+=(--add-label "$add_label")
    fi
    local remove
    for remove in "$@"; do
      edit_args+=(--remove-label "$remove")
    done
    if [ "${#edit_args[@]}" -gt 0 ]; then
      gh issue edit "$ISSUE" --repo "$TEMPLATE_REPO" "${edit_args[@]}" 2>/dev/null || true
    fi
    if [ -n "$close_reason" ]; then
      gh issue close "$ISSUE" --repo "$TEMPLATE_REPO" --reason "$close_reason" >/dev/null || true
    fi
  else
    echo "--- sticky comment (dry run) ---"
    printf '%s\n' "$body_out"
  fi

  {
    echo "$headline"
    echo
    echo "| | step | detail |"
    echo "| --- | --- | --- |"
    printf '%s\n' "$table"
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

  [ "$OVERALL" = "failed" ] && exit 1
  exit 0
}

# ==========================================================================
# rollback — seed only. Never deletes a repository.
# ==========================================================================
if [ "$COMMAND" = "rollback" ]; then
  refuse=false
  if gh repo view "$TARGET" --json name >/dev/null 2>&1; then
    commits="$(gh api "/repos/${TARGET}/commits" --jq 'length' 2>/dev/null || echo 99)"
    branches="$(gh api "/repos/${TARGET}/branches" --jq 'length' 2>/dev/null || echo 99)"
    if [ "$commits" -gt 1 ] || [ "$branches" -gt 1 ]; then
      step failed "rollback" "\`${TARGET}\` has ${commits} commit(s) on ${branches} branch(es), more than the generated snapshot. Comment \`/offboard\`."
      refuse=true
    else
      step done "repository" "\`${TARGET}\` still has only the generated commit. It is left in place."
    fi
  else
    step done "repository" "\`${TARGET}\` does not exist"
  fi
  if membership_was_applied; then
    step failed "rollback" "a membership pull request for \`${TARGET}\` has merged. Comment \`/offboard\`."
    refuse=true
  fi
  if [ "$refuse" = "true" ]; then
    finish "## Rollback for \`${REPO_NAME}\` — refused" "" "" \
      "Comment \`/offboard\` to retire an engagement that has been used. Rollback does not delete repositories and does not remove a slug that was already applied." \
      "onboarding:in-progress"
  fi
  close_membership_pr "onboard/${REPO_NAME}"
  finish "## Rollback for \`${REPO_NAME}\`" "" "not planned" \
    "The membership pull request is closed when one was open. The GitHub repository, if it exists, is left in place. Comment \`/onboard\` to resume." \
    "onboarding:in-progress" "onboarding:failed" "onboarding:blocked"
fi

# ==========================================================================
# verify — close the issue only after two bundle publishes
# ==========================================================================
# Do not dispatch jfrog-oidc-test.yaml. Its JF_PROJECT expression falls
# through to ps-jf, which is the mapping this check exists to avoid.
if [ "$COMMAND" = "verify" ]; then
  if ! gh repo view "$TARGET" --json name >/dev/null 2>&1; then
    step failed "repository" "\`${TARGET}\` does not exist"
    finish "## Verification for \`${REPO_NAME}\` — failed" "onboarding:failed" "" \
      "Comment \`/onboard\` first." \
      "onboarding:in-progress" "onboarding:blocked"
  fi
  if GH_TOKEN="${APP_TOKEN:-$GH_TOKEN}" gh variable list --repo "$TARGET" 2>/dev/null | grep -q '^JF_PROJECT'; then
    step failed "no JF_PROJECT" "\`JF_PROJECT\` is set on \`${TARGET}\`. Delete it before verifying."
  else
    step done "no JF_PROJECT" "confirmed unset"
  fi

  prove_bundle() {
    local label="$1"
    local since run_id log i
    since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$DRY_RUN" = "true" ]; then
      step skipped "publish ${label}" "would dispatch jfrog-ps-bundle.yaml on \`${TARGET}\` (dry run)"
      return 0
    fi
    if [ "$APP_OK" != "true" ] || ! app_can_reach "$TARGET"; then
      step blocked "publish ${label}" "the App cannot dispatch workflows on \`${TARGET}\`"
      blocker "Dispatching **Build JFrog PS Engagement Bundle** needs the App installed on \`${TARGET}\` with **Actions: write**."
      return 1
    fi
    local err
    if ! err="$(GH_TOKEN="$APP_TOKEN" gh api --method POST \
      "/repos/${TARGET}/actions/workflows/jfrog-ps-bundle.yaml/dispatches" \
      --input - <<<"$(jq -n --arg ref "$SEED_BRANCH" '{ref:$ref}')" 2>&1)"; then
      step blocked "publish ${label}" "dispatch was refused"
      blocker "\`POST /repos/${TARGET}/actions/workflows/jfrog-ps-bundle.yaml/dispatches\` failed (${err}). The App needs **Actions: write** on \`${TARGET}\`."
      return 1
    fi
    run_id=""
    for _ in $(seq 1 30); do
      sleep 10
      run_id="$(GH_TOKEN="$APP_TOKEN" gh run list --repo "$TARGET" --workflow jfrog-ps-bundle.yaml \
        --event workflow_dispatch --limit 5 \
        --json databaseId,createdAt --jq "[.[] | select(.createdAt >= \"${since}\")] | .[0].databaseId // empty" 2>/dev/null || true)"
      [ -n "$run_id" ] && break
    done
    if [ -z "$run_id" ]; then
      step failed "publish ${label}" "dispatch succeeded but no run appeared"
      return 1
    fi
    local url="https://github.com/${TARGET}/actions/runs/${run_id}"
    if ! GH_TOKEN="$APP_TOKEN" gh run watch "$run_id" --repo "$TARGET" --exit-status >/dev/null; then
      step failed "publish ${label}" "run failed: ${url}"
      return 1
    fi
    log="$(GH_TOKEN="$APP_TOKEN" gh run view "$run_id" --repo "$TARGET" --log 2>/dev/null || true)"
    if ! grep -q '(downloaded)' <<<"$log"; then
      step failed "publish ${label}" "${url} did not download scripts-general-util"
      return 1
    fi
    if ! grep -q 'Build info successfully deployed' <<<"$log"; then
      step failed "publish ${label}" "${url} did not deploy build-info"
      return 1
    fi
    step done "publish ${label}" "${url} downloaded scripts-general-util and deployed build-info"
  }

  if [ "$OVERALL" != "failed" ]; then
    prove_bundle "first" || true
  fi
  if [ "$OVERALL" != "failed" ] && [ "$OVERALL" != "blocked" ]; then
    prove_bundle "second" || true
  fi
  if [ "$OVERALL" = "done" ]; then
    finish "## Verification for \`${REPO_NAME}\` — passed" "onboarding:done" "completed" \
      "Both publishes succeeded, including the second upload to the same CalVer path. That is the \`DELETE_OVERWRITE_REPOSITORY\` proof. The issue is closed." \
      "onboarding:in-progress" "onboarding:failed" "onboarding:blocked"
  fi
  if [ "$OVERALL" = "blocked" ]; then
    finish "## Verification for \`${REPO_NAME}\` — waiting on a permission" "onboarding:blocked" "" \
      "The issue stays open. Grant the permission and comment \`/onboard-verify\` again." \
      "onboarding:in-progress" "onboarding:failed" "onboarding:done"
  fi
  finish "## Verification for \`${REPO_NAME}\` — not closed" "onboarding:failed" "" \
    "The issue stays open. Fix the failure and comment \`/onboard-verify\` again. Do not use **Test OIDC to JFrog** for this: that workflow defaults \`JF_PROJECT\` to \`ps-jf\`." \
    "onboarding:in-progress" "onboarding:blocked" "onboarding:done"
fi

# ==========================================================================
# offboard — dispatch the removal, then stop
# ==========================================================================
if [ "$COMMAND" = "offboard" ]; then
  if [ "$REPO_NAME" = "ps-customer-template" ]; then
    step failed "membership" "\`ps-customer-template\` is not an engagement"
    finish "## Offboard \`${REPO_NAME}\` — refused" "" "" \
      "This repository stays in \`ps_engagement_repos\`." \
      "onboarding:in-progress"
  fi
  open_remove="$(gh pr list --repo "$TF_REPO" --state open --head "offboard/${REPO_NAME}" \
    --json url --jq '.[0].url // empty' 2>/dev/null || true)"
  if [ -n "${open_remove}" ]; then
    step done "membership" "removal pull request already open: ${open_remove}"
  else
    dispatch_membership remove || true
  fi
  finish "## Offboard \`${REPO_NAME}\` — removal requested" "engagement:retiring" "" \
    "Merge the removal pull request and apply it on acrois with \`TF_VAR_plugin_project=ps-jf\`. Published bytes under \`ps-jfrog-ps-bundles/${REPO_NAME}/\` stay. Then comment \`/offboard-finish\` to archive the GitHub repository and close this issue. \`/offboard-finish\` is the confirmation that the apply has happened." \
    "onboarding:in-progress" "engagement:due" "onboarding:failed" "onboarding:blocked"
fi

# ==========================================================================
# offboard-finish — archive, after a merged removal
# ==========================================================================
if [ "$COMMAND" = "offboard-finish" ]; then
  merged_remove="$(gh pr list --repo "$TF_REPO" --state merged --limit 20 --search "remove ${TARGET} in:title" \
    --json number,title | jq -r --arg needle "remove ${TARGET}" \
    '[.[] | select(.title | contains($needle))][0].number // empty' 2>/dev/null || true)"
  if [ -z "${merged_remove}" ]; then
    step failed "removal merged" "no merged pull request titled \`feat: remove ${TARGET}\`. Merge and apply that change before archiving."
    finish "## Offboard \`${REPO_NAME}\` — not archived" "engagement:retiring" "" \
      "Archive waits until the removal pull request has merged. Apply it on acrois, then comment \`/offboard-finish\` again." \
      "onboarding:in-progress"
  fi
  step done "removal merged" "${TF_REPO}#${merged_remove}"
  if [ "$DRY_RUN" = "true" ]; then
    step skipped "archive" "would set \`${TARGET}\` archived (dry run)"
  elif [ "$(gh api "/repos/${TARGET}" --jq '.archived' 2>/dev/null || echo false)" = "true" ]; then
    step done "archive" "\`${TARGET}\` is already archived"
  elif GH_TOKEN="${APP_TOKEN:-$GH_TOKEN}" gh api --method PATCH "/repos/${TARGET}" -F archived=true >/dev/null 2>&1; then
    step done "archive" "\`${TARGET}\` is archived. Published bundle bytes were left in place."
  else
    step blocked "archive" "cannot archive \`${TARGET}\`"
    blocker "Archiving needs **Repository permissions -> Administration: write** on the App for \`${TARGET}\`."
  fi
  if [ "$OVERALL" = "done" ]; then
    finish "## Offboard \`${REPO_NAME}\` — retired" "engagement:retired" "completed" \
      "The GitHub repository is archived and this issue is closed. The bundle objects in Artifactory were not deleted." \
      "engagement:retiring" "engagement:due" "onboarding:in-progress" "onboarding:failed" "onboarding:blocked" "onboarding:done"
  fi
  finish "## Offboard \`${REPO_NAME}\` — not archived" "engagement:retiring" "" \
    "The issue stays open until the repository is archived." \
    "onboarding:in-progress"
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
# Create with `POST /repos/{template}/generate`, not `POST /orgs/{org}/repos`.
# An empty repository plus a push of template history has no
# `template_repository` marker, and that marker is what "based off the
# template" means. Do not "simplify" this back to an empty repo. Do not push
# template history over a generated repository either: that orphans the
# snapshot GitHub recorded as the Initial commit.
#
# Re-tested live on 2026-10-05 against ps-jfrog/ps-customer-template:
#   * `custom_properties` in the /generate JSON body is rejected with 422
#     "not a permitted key". GraphQL cloneTemplateRepository has no properties
#     field either. There is no supported generate field for the property.
#   * /generate into this org, while `ps_data_class` has
#     `require_explicit_values: true`, returns 422 "Could not clone:
#     Repository Property 'ps_data_class' requires an explicit value to be
#     set". The repository is not created, so a following PATCH cannot run.
#   * The sequence that both sets `template_repository` and satisfies the
#     property: briefly clear `require_explicit_values`, /generate into the
#     org (`private` from the form), PATCH
#     `/repos/{owner}/{repo}/properties/values` to `ps_data_class=Customer`,
#     then restore the flag to whatever it was. The App holds
#     `organization_custom_properties: write` for that schema update and
#     `repository_custom_properties: write` for the value.
# The flag is an org-wide switch. Restore it even when generate fails, and
# fail the run if the restore itself fails.
CREATED_THIS_RUN=false
if [ "$REPO_EXISTS" = "true" ]; then
  step done "create repository" "[\`${TARGET}\`](https://github.com/${TARGET}) already exists — not touched"
elif [ "$DRY_RUN" = "true" ]; then
  step skipped "create repository" "would \`POST /repos/${TEMPLATE_REPO}/generate\` (private=${VISIBILITY}) then set \`ps_data_class=${PS_DATA_CLASS}\` (dry run)"
elif [ "$APP_OK" != "true" ]; then
  step blocked "create repository" "no usable App token"
  blocker "The App token could not be minted. Check \`vars.APP_CLIENT_ID\` and \`secrets.APP_PRIVATE_KEY\` on \`${TEMPLATE_REPO}\`."
else
  schema_url="/orgs/${ORG}/properties/schema"
  saved_schema="$(GH_TOKEN="$APP_TOKEN" gh api "${schema_url}/ps_data_class" 2>/tmp/onboard-schema-err || true)"
  if [ -z "$saved_schema" ] || ! jq -e '.property_name' <<<"$saved_schema" >/dev/null; then
    step blocked "create repository" "cannot read the \`ps_data_class\` schema"
    blocker "Reading the org custom property failed: $(tr '\n' ' ' </tmp/onboard-schema-err). The App needs **Organization permissions -> Custom properties: read**."
  else
    original_explicit="$(jq -r '.require_explicit_values' <<<"$saved_schema")"
    schema_body() {
      jq -n --argjson s "$saved_schema" --argjson explicit "$1" '{
        properties: [{
          property_name: $s.property_name,
          value_type: $s.value_type,
          required: $s.required,
          default_value: $s.default_value,
          description: $s.description,
          allowed_values: $s.allowed_values,
          values_editable_by: $s.values_editable_by,
          require_explicit_values: $explicit
        }]
      }'
    }
    restore_explicit() {
      local err
      err="$(GH_TOKEN="$APP_TOKEN" gh api --method PATCH "$schema_url" \
        --input - <<<"$(schema_body "$original_explicit")" 2>&1 >/dev/null)" || {
        echo "::error::failed to restore ps_data_class require_explicit_values=${original_explicit}: ${err}"
        return 1
      }
      local now
      now="$(GH_TOKEN="$APP_TOKEN" gh api "${schema_url}/ps_data_class" --jq '.require_explicit_values' 2>/dev/null || echo missing)"
      [ "$now" = "$original_explicit" ]
    }
    # If the step is killed after the flag is cleared, put it back.
    trap 'if [ "${relaxed:-false}" = "true" ]; then restore_explicit || echo "::error::could not restore ps_data_class on exit"; fi' EXIT

    relaxed=false
    if [ "$original_explicit" = "true" ]; then
      if relax_err="$(GH_TOKEN="$APP_TOKEN" gh api --method PATCH "$schema_url" \
        --input - <<<"$(schema_body false)" 2>&1 >/dev/null)"; then
        relaxed=true
      else
        step blocked "create repository" "cannot clear \`require_explicit_values\` on \`ps_data_class\`"
        blocker "\`PATCH ${schema_url}\` was refused (${relax_err}). /generate has no custom-properties field, and with the flag set it 422s before a repository exists. The App needs **Organization permissions -> Custom properties: write**. Do not fall back to \`POST /orgs/${ORG}/repos\`."
      fi
    fi

    if [ "$original_explicit" != "true" ] || [ "$relaxed" = "true" ]; then
      private=false
      [ "$VISIBILITY" = "private" ] && private=true
      gen_err=""
      if gen_err="$(GH_TOKEN="$APP_TOKEN" gh api --method POST "/repos/${TEMPLATE_REPO}/generate" \
        --input - <<<"$(jq -n \
          --arg owner "$ORG" \
          --arg name "$REPO_NAME" \
          --arg description "JFrog PS engagement — ${CUSTOMER_NAME}" \
          --argjson private "$private" \
          '{owner:$owner, name:$name, description:$description, private:$private, include_all_branches:false}')" 2>&1 >/dev/null)"; then
        REPO_EXISTS=true
        CREATED_THIS_RUN=true
        prop_err=""
        if prop_err="$(GH_TOKEN="$APP_TOKEN" gh api --method PATCH "/repos/${TARGET}/properties/values" \
          --input - <<<"$(jq -n --arg cls "$PS_DATA_CLASS" \
            '{properties:[{property_name:"ps_data_class", value:[$cls]}]}')" 2>&1 >/dev/null)"; then
          step done "create repository" "generated [\`${TARGET}\`](https://github.com/${TARGET}) from \`${TEMPLATE_REPO}\` and set \`ps_data_class=${PS_DATA_CLASS}\`"
        else
          step failed "create repository" "generated \`${TARGET}\` but setting \`ps_data_class\` failed"
          blocker "\`PATCH /repos/${TARGET}/properties/values\` failed: ${prop_err}"
          echo "::warning::${prop_err}"
        fi
      else
        step blocked "create repository" "\`POST /repos/${TEMPLATE_REPO}/generate\` was refused"
        blocker "Generate failed (${gen_err}). Empty-repo creation is not the fallback."
        echo "::warning::${gen_err}"
      fi
    fi

    if [ "$relaxed" = "true" ]; then
      if restore_explicit; then
        relaxed=false
        step done "restore ps_data_class rule" "\`require_explicit_values\` is \`${original_explicit}\` again"
      else
        step failed "restore ps_data_class rule" "\`require_explicit_values\` was cleared and could not be restored to \`${original_explicit}\`"
        blocker "Restore \`ps_data_class.require_explicit_values\` to \`${original_explicit}\` by hand. Until then new repositories in \`${ORG}\` are not forced to choose a value."
      fi
    fi
  fi
fi

# --- template marker ------------------------------------------------------
# Confirm the marker and stop. Pushing this checkout's history onto the
# generated branch would orphan the Initial commit. An existing repository is
# left alone even when it has no marker (idempotent re-run).
if [ "$REPO_EXISTS" != "true" ]; then
  step skipped "template marker" "no repository yet"
elif [ "$DRY_RUN" = "true" ]; then
  step skipped "template marker" "would require \`template_repository=${TEMPLATE_REPO}\` and would not push history (dry run)"
else
  marker="$(GH_TOKEN="${APP_TOKEN:-$GH_TOKEN}" gh api "/repos/${TARGET}" \
    --jq '.template_repository.full_name // empty' 2>/dev/null || true)"
  if [ "$CREATED_THIS_RUN" = "true" ] && [ "$marker" != "$TEMPLATE_REPO" ]; then
    step failed "template marker" "\`${TARGET}\` reports \`${marker:-no template_repository}\`, expected \`${TEMPLATE_REPO}\`. History was not pushed."
  elif [ "$marker" = "$TEMPLATE_REPO" ]; then
    step done "template marker" "\`${marker}\` on \`${SEED_BRANCH}\`. History was not pushed over the generated snapshot."
  else
    step done "template marker" "existing repository left as-is (\`template_repository=${marker:-none}\`)"
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
  [ -n "${ENGAGEMENT_ENDS:-}" ] && wanted+=("ENGAGEMENT_ENDS=${ENGAGEMENT_ENDS}")

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

# --- membership ----------------------------------------------------------
# Do not clone acrois-tf-oidc-bootstrap from here. terraform.tfvars is
# git-crypt ciphertext; reading it as text is the UnicodeDecodeError that
# left every onboarding issue failed. The bootstrap workflow unlocks, plans,
# and opens the pull request. This step only dispatches it.
existing_tf_pr="$(gh pr list --repo "$TF_REPO" --state open --head "onboard/${REPO_NAME}" \
  --json url --jq '.[0].url // empty' 2>/dev/null || true)"
if [ -n "${existing_tf_pr}" ]; then
  step done "membership" "pull request already open: ${existing_tf_pr}"
else
  dispatch_membership add || true
fi

step skipped "verification" \
  "comment \`/onboard-verify\` after the membership pull request has been merged and applied on acrois. This command does not publish, and it does not close the issue."

# The issue stays open. `/onboard-verify` is what closes it, after two publishes.
REMAINS="Fan-out discovers this repository from \`template_repository\`. The App must be installed on \`${TARGET}\`.

Merge the membership pull request in \`${TF_REPO}\` and apply it on acrois with \`TF_VAR_plugin_project=ps-jf\`. Then comment \`/onboard-verify\`. That dispatches the bundle workflow twice. The issue closes only when both succeed, including the second upload to the same path.

Comment \`/onboard\` to resume a failed step. Comment \`/onboard-rollback\` only while the repository still has just the generated commit and the slug has not been applied. Comment \`/offboard\` to retire the engagement later."

case "$OVERALL" in
blocked)
  finish "## Onboarding \`${REPO_NAME}\` — waiting on a permission" "onboarding:blocked" "" \
    "$REMAINS" \
    "onboarding:in-progress" "onboarding:failed"
  ;;
failed)
  finish "## Onboarding \`${REPO_NAME}\` — failed" "onboarding:failed" "" \
    "$REMAINS" \
    "onboarding:in-progress" "onboarding:blocked"
  ;;
*)
  finish "## Onboarding \`${REPO_NAME}\` — waiting on apply" "onboarding:in-progress" "" \
    "$REMAINS" \
    "onboarding:failed" "onboarding:blocked" "onboarding:done"
  ;;
esac
