#!/usr/bin/env bash
#
# File an offboard issue for each engagement whose ENGAGEMENT_ENDS is today
# or earlier. Does not dispatch Terraform, does not archive, and does not
# comment `/offboard` — the actor here is github-actions, which is not in
# CODEOWNERS.
#
# Env: APP_TOKEN  installation token that can list repos and read variables
#      GH_TOKEN   token with issues:write on the template repository

set -euo pipefail

TEMPLATE_REPO="${TEMPLATE_REPO:-ps-jfrog/ps-customer-template}"
: "${APP_TOKEN:?APP_TOKEN is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

due() {
  python3 -c 'import datetime, sys
try:
    ends = datetime.date.fromisoformat(sys.argv[1])
except ValueError:
    sys.exit(2)
sys.exit(0 if ends <= datetime.date.today() else 1)' "$1"
}

GH_TOKEN="$APP_TOKEN" gh api /installation/repositories --paginate \
  --jq '.repositories[] | [.full_name, (.archived | tostring)] | @tsv' |
  while IFS=$'\t' read -r repo archived; do
    [ -n "$repo" ] || continue
    [ "$archived" = "true" ] && continue
    [ "$repo" = "$TEMPLATE_REPO" ] && continue
    name="${repo#*/}"
    [[ "$name" == ps-customer-* ]] || continue

    marker="$(GH_TOKEN="$APP_TOKEN" gh api "/repos/${repo}" --jq '.template_repository.full_name // empty' 2>/dev/null || true)"
    [ "$marker" = "$TEMPLATE_REPO" ] || continue

    ends="$(GH_TOKEN="$APP_TOKEN" gh variable get ENGAGEMENT_ENDS --repo "$repo" 2>/dev/null || true)"
    [ -n "$ends" ] || continue
    due "$ends" || continue

    slug="${name#ps-customer-}"
    existing="$(gh issue list --repo "$TEMPLATE_REPO" --state open --limit 20 \
      --search "offboard: ${name} in:title" --json number --jq '.[0].number // empty')"
    if [ -n "$existing" ]; then
      echo "open offboard issue already exists for ${name}: #${existing}"
      continue
    fi

    echo "filing offboard issue for ${name} (ENGAGEMENT_ENDS=${ends})"
    gh issue create --repo "$TEMPLATE_REPO" \
      --title "offboard: ${name}" \
      --label "engagement:due" \
      --body "$(cat <<EOF
### Slug

${slug}

### Confirmation

- [x] Retire \`${repo}\`. This issue was filed because \`ENGAGEMENT_ENDS\` (${ends}) has arrived. Comment \`/offboard\` to open the removal pull request. This schedule does not dispatch Terraform and does not archive the repository.
EOF
)"
  done
