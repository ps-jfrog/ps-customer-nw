# Anonymizing customer identifiers

Status: proposal. Nothing here is applied. This describes the target, the order
of work, and the runbook for renaming the existing engagement repositories.

## Goal

A GitHub repository name, an Artifactory path, a Terraform key or a CI log line
must not reveal which customer an engagement is for. Identifiers become
Salesforce IDs. The only place that maps an ID back to a name is an encrypted
file that few people can read.

## Non-goals, said plainly

Renaming is **not retroactive anonymity**. After a rename these still carry the
old name unless handled separately:

- GitHub keeps a redirect from the old repository name. It stays until another
  repository takes that name.
- Git history: commit messages, file content, tags, branch names.
- Issues, pull requests and their comments; Actions run history and logs.
- JFrog build-info is named `<owner>/<repo>`; published bundle paths; Terraform
  state and plan history.
- Anything already sent to a customer or a third party.

The rename removes the name from the places people routinely see. It does not
erase it. Phase 4 deals with history deliberately instead of by accident.

## Identifier scheme

Structure is account, then project. A repository is **account-level**; projects
are folders in it.

| Thing | Value |
| --- | --- |
| Repository | `ps-customer-<account-id>` |
| Slug (everything keyed on it) | the Salesforce Account ID, lowercased |
| Project | a folder `projects/<project-id>/` inside the repository |
| Bundle path | `ps-jfrog-ps-bundles/<account-id>/…` (one bundle per repository, unchanged shape) |

Use the **18-character** Account ID. The 15-character form is case-sensitive;
lowercasing it loses information. The 18-character form carries a checksum
suffix that keeps it unique when case is dropped, so a lowercase slug is safe.
Normalise anything pasted in to 18 characters, lowercase.

Validation: `^001[a-z0-9]{15}$` (Account IDs start `001`). The current slug rule,
`^[a-z0-9][a-z0-9-]{1,28}$`, already admits it, so Terraform, group names and
`<slug>/**` patterns need no widening.

A project ID is the custom entity's ID. It is recorded in the map and as a
folder name; it is not part of the repository or group name. If a project ever
needs its own bundle or its own permission, the bundle path becomes
`<account-id>/<project-id>/…` and the group pattern follows. That is a separate
decision, not required to start.

## The map

Source of truth: a git-crypt'd file in `acrois-tf-oidc-bootstrap`, the
repository that already holds `terraform.tfvars` under git-crypt and already
owns `ps_engagement_repos`.

```text
customer-map/accounts.json     # git-crypt, via .gitattributes
```

```json
{
  "001000000000000AAA": {
    "name": "Example Corp",
    "aliases": ["Example", "ExampleCo"],
    "projects": { "a0X000000000000AAA": "Platform migration" }
  }
}
```

Aliases matter: the scan needs every string a person might type, not only the
legal name. Names short enough to be ordinary words need the same care the
current `--min-length` rule gives bare slugs.

The file is produced by an export from Salesforce and committed by a reviewed PR.
Who can decrypt is whoever holds the git-crypt key for that repository, which is
already a small, controlled set. The template and the customer repositories
never hold that key.

## Why the identifier scan has to change

`find_customer_identifiers` builds its list from `ps-customer-*` repository
names. Once those are Salesforce IDs, the scan would check for the IDs and stop
catching the real names in text. It becomes weaker, silently. The name list has
to come from the map.

The scan runs in the template and in every derived repository, none of which may
hold the git-crypt key. Proposed: a job in `acrois-tf-oidc-bootstrap` unlocks the
map, derives a flat list of names and aliases, and writes it to an organization
Actions secret `PS_CUSTOMER_NAMES` scoped to the template and the engagement
repositories. `customer-name-check.yaml` reads the secret instead of calling
GitHub for repository names.

Trade-offs to accept knowingly:

- Anyone who can add a workflow to a repository that holds the secret can read it,
  as with any secret. Engagement repositories are private and write access is
  already limited.
- The secret holds plaintext names, so it must never be echoed. Masking is
  automatic for secrets but not for substrings; the scan must not print the
  matched name, only the file and line.
- The org-secret write needs the App's organization secrets permission. Confirm
  before relying on it.

During the transition the scan reads the **union** of the secret and today's
`ps-customer-*` discovery, so nothing is lost while repositories are renamed.

## Onboarding form and scripts

Replace *Customer name* and *Slug* with **Salesforce Account ID**. Add an
optional **Project ID**.

- `parse-onboarding-issue.py`: `SLUG_RE` becomes the Account ID rule; `SLUG` is
  the normalised ID; `REPO_NAME` stays `ps-customer-{slug}`.
- Repository description carries the Account ID only. No name, no link.
- `onboard-customer.sh`: no logic change beyond the validation message and the
  description; every step is already keyed on the slug.
- The customer-technical-contact field stays "recorded on the issue only".
  Consider dropping it, since it is the one free-text field that invites a name.

## Renaming the existing repositories

One repository at a time, lowest-risk first. Treat the first as a rehearsal on a
repository with no live engagement.

For each `ps-customer-<old>` → `ps-customer-<account-id>`:

1. **Resolve the ID.** Look the account up in the map. No ID, no rename.
2. **Terraform, add before remove.** In `ps_engagement_repos` add the new entry
   first. The per-repository group, permission, build-info permission and OIDC
   identity mapping are keyed by repository name, so a one-step swap destroys
   and recreates them and leaves a window with no mapping. Apply with the new
   entry present, migrate, then remove the old entry in a second PR.
   Apply with `TF_VAR_plugin_project=ps-jf`; without it the plan proposes
   destroying the plugin stack.
3. **Artifactory.** Copy `ps-jfrog-ps-bundles/<old>/` to `<account-id>/` so every
   published version survives. Pins elsewhere reference bundle names, not the
   customer repository, but anything that downloads `<old>/` directly (shared
   links, a customer's own automation) breaks. List those before cutting over.
4. **GitHub rename** through the API. Secrets, variables, `ENGAGEMENT_ENDS` and
   environments follow the repository. Check the OIDC subject claim: it contains
   the repository name, which is why step 2 comes first.
5. **Template repository.** Update `sync-targets.json` and `CODEOWNERS` entries
   that name the old repository. Fan-out discovery uses the template marker, so
   it follows the rename without an edit unless the repository is listed
   explicitly.
6. **Verify.** A bundle build on the renamed repository publishes under the new
   path; the scan passes; the customer deliverable resolves.
7. **Remove the old Terraform entry.**

Rollback: GitHub renames are reversible, and the Artifactory copy leaves the old
path intact until step 7, so a failed rename can be undone before anything is
deleted.

## Order of work

| Phase | Where | Change |
| --- | --- | --- |
| 0 | `acrois-tf-oidc-bootstrap` | `customer-map/` under git-crypt; job that derives `PS_CUSTOMER_NAMES` |
| 1 | template | scan reads the secret, union with current discovery |
| 2 | template | onboarding form and parser take an Account ID; new engagements use it |
| 3 | per repository | rename runbook above, rehearsal first |
| 4 | everywhere | scan history for old names; decide rewrite versus accept; drop the scan's path exclusions that exist only because real names appeared in docs |

Phase 1 comes before any rename. Doing it last is how a leak slips through
during the move.

## Open questions

1. Is a bundle per project needed, or is one bundle per account enough?
2. The format of the project entity's ID, and whether it needs validating.
3. Who owns the Salesforce export and how often it runs. A stale map is a
   scan that misses a newly signed customer.
4. Whether the App may write organization secrets, or whether the secret is
   set by hand.
5. Whether to rewrite history to remove old names, accept it, or archive and
   replace the oldest repositories. Rewriting history breaks every clone and
   open pull request.
