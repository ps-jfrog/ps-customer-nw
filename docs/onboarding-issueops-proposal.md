# Proposal: IssueOps customer onboarding from the template repo

Status: **proposal, uncommitted.** Written 2026-09-11. Open questions are
marked and are genuinely open — this is not a finished spec.

## Why this document exists

Onboarding a PS customer engagement today is a sequence of hand steps that
nobody wrote down, and the audit of the eleven existing derived repos shows
exactly what that costs:

| Symptom | Repos affected |
| --- | --- |
| No `JF_NAME` set, so every JFrog step resolves `https://.jfrog.io` | `ks`, `pnc`, `asr`, `allstate`, `nw`, `gco` |
| No `APP_CLIENT_ID`/`APP_PRIVATE_KEY`, so every App-token step fails | `ks`, `pnc`, `asr`, `allstate`, `nw`, `gco` (and `gco` has the key but not the id) |
| Not in `ps_engagement_repos`, so no JFrog group, permission, or OIDC mapping | `eq`, `ks`, `pnc`, `mgm`, `asr`, `allstate`, `nw`, `gco` |
| `PREFERRED_RUNNER=standard` pointing at an offline pool | `ej`, `gmit`, `mgm`, `medtronic` |
| Never once completed a template sync | `ks`, `pnc`, `asr`, `allstate`, `nw`, `gco`, `gmit` |

Every one of those is a missing step in an unwritten checklist. The point of
IssueOps here is not automation for its own sake — it is to make the checklist
executable so the twelfth repo does not join that table.

A second, harder constraint comes out of the audit: **`sync-template` cannot
carry the submodule-to-artifact migration.** Replaying the merge locally
produces a tree that keeps `.gitmodules` and the `scripts-general-util` gitlink
*and* adds `ps-bundle.deps.json`, with conflict markers committed into `.envrc`
(no longer parses) and into two workflow files (no longer valid YAML). So
onboarding must produce repos that are *born* on the artifact model. It cannot
assume a migration path exists, because there isn't one.

## Phase 0 — prerequisites that are not IssueOps

These are ordinary fixes that the proposal depends on. Doing IssueOps first
would just automate the creation of broken repos.

1. **Org-level `ORG_APP_CLIENT_ID` / `ORG_APP_PRIVATE_KEY`.** Both
   `sync-template.yaml` and `jfrog-ps-bundle.yaml` already fall back to them
   (`vars.APP_CLIENT_ID || vars.ORG_APP_CLIENT_ID`). The fallback has never
   resolved, which is why six repos fail at step 2 of every run. Setting the
   org pair once fixes six repos and removes a per-repo onboarding step
   permanently. This is the single highest-leverage change in the whole
   document and it is not automation.

2. **Fix `sync-template`'s self-latching push.** The workflow pushes with
   `git push --force-with-lease <tokenised-url> HEAD:refs/heads/chore/sync-template`.
   Because the URL is not a configured remote, git has no remote-tracking ref
   to form a lease from, so the push is rejected with `stale info` whenever the
   branch already exists remotely. The first sync that opens a PR therefore
   guarantees that every later sync fails until a human merges or closes it.
   This is measured, not theorised: `mgm` run #11 succeeded and opened PR #1 on
   2026-07-20, and runs #12 through #18 all failed at the push step; `ej`
   escaped only because it has `delete_branch_on_merge=true` and its PRs were
   actually merged. Fix by fetching the branch and leasing against it, or by
   adding the token URL as a named remote, or by dropping to `--force` on a
   bot-owned branch. Also turn on `delete_branch_on_merge` org-wide.

3. **Decide the migration story for the eight submodule-era repos** and do it
   by hand, with the `git submodule deinit` recipe already in the template
   README. IssueOps should not attempt it.

4. **Un-stale `.cursor/rules/consult-submodule-rules.mdc`**, which still tells
   agents that `scripts-general-util` is a submodule.

> **Open question.** Is the `standard` self-hosted pool meant to be permanently
> available? Four repos point at it and it was down on 2026-09-07 long enough
> for GitHub's 24-hour queue timeout to cancel their jobs. If it is
> best-effort, onboarding should not set `PREFERRED_RUNNER` by default.

## Phase 1 — the issue form

New file: `.github/ISSUE_TEMPLATE/onboard-customer.yml`.

The fields are chosen to be exactly the inputs the audit showed missing. Each
one maps to a concrete artifact, and nothing is collected that the automation
does not consume.

| Field | id | Consumed by |
| --- | --- | --- |
| Customer display name | `customer_name` | repo description, JFrog group description |
| Slug (`^[a-z0-9][a-z0-9-]{1,28}$`) | `slug` | repo name `ps-customer-<slug>`, bundle subfolder, group name |
| Visibility (private / public) | `visibility` | repo creation |
| Shared components (checkboxes, default `scripts-general-util`) | `shared` | `ps-bundle.deps.json` entries |
| Runner (`ubuntu-latest` / `standard`) | `runner` | `PREFERRED_RUNNER` variable |
| JPD base name (default `acrois`) | `jf_name` | `JF_NAME` variable |
| Sizing / flavor (small / medium / large; k8s / OpenShift / compose) | `sizing`, `flavor` | which `jfrog-helm-values` compose labels get symlinked |
| Engagement lead (GitHub handle) | `lead` | repo admin, `CODEOWNERS` |
| Customer technical contact | `contact` | issue record only |
| Target JFrog project key, or blank | `project_key` | see the warning in Phase 4 — **default must be blank** |

The slug pattern matters more than it looks: it becomes an Artifactory
`include_patterns` entry (`<slug>/**`) and a group name, so anything outside
`[a-z0-9-]` either silently fails to match or produces an unusable group.

## Phase 2 — the dispatching workflow

New file: `.github/workflows/onboard-customer.yml`.

```yaml
on:
  issues:
    types: [labeled]
  issue_comment:
    types: [created]

permissions:
  contents: read
  issues: write

jobs:
  onboard:
    # Non-negotiable. See "Why the no-op guard" below.
    if: |
      github.repository == 'ps-jfrog/ps-customer-template' &&
      (
        (github.event_name == 'issues' && github.event.label.name == 'onboarding') ||
        (github.event_name == 'issue_comment' &&
         startsWith(github.event.comment.body, '/onboard'))
      )
    runs-on: ubuntu-latest
```

### Why the no-op guard

The template's whole purpose is to be copied. Anything committed here lands in
every customer repo on the next sync, and a repo-creating workflow that
activates in a customer repo is an org-wide footgun: it would try to create
repos, mint App tokens, and write JFrog permissions from a repo whose audience
includes the customer. `sync-template.yaml` already establishes the pattern in
the opposite direction (`if: github.repository != (vars.TEMPLATE_REPO || ...)`),
so the idiom is familiar in this codebase.

The guard must be a literal repository comparison, not `vars.TEMPLATE_REPO`.
`sync-template` allows the variable override because a fork-of-the-template
workflow is harmless; here, a customer repo that sets `TEMPLATE_REPO` to its own
name would re-enable repo creation. Hardcode it.

Belt and braces: keep the App credentials out of reach as well, so that even a
guard regression cannot escalate. That means the App is installed on the
template repo only (Phase 3), which makes the automation fail closed.

### Authorisation

The issue author is not the authoriser. Two checks, both cheap:

1. The actor must be a member of a nominated team (`gh api
   orgs/ps-jfrog/teams/ps-engagement-leads/memberships/<actor>`). Team
   membership is the right primitive because it is already how repo access is
   granted.
2. The onboarding definition files in the template must be `CODEOWNERS`-owned
   by that same team, so changing the automation requires the same trust as
   running it.

There is no `CODEOWNERS` in this repo yet; adding one is part of this phase.

> **Open question.** Should a second approver be required — for example, the
> workflow posts a plan and waits for a `/approve` from a different team member?
> Given that onboarding writes to the JFrog platform, a two-person rule is
> defensible. It also doubles the latency of every onboarding.

### Validation and progress reporting

Parse the issue body with `github-script` and the form's field ids. Validate
before touching anything:

- slug matches the pattern and `ps-jfrog/ps-customer-<slug>` does not exist;
- `<slug>` is not already a subfolder in the bundles repo;
- each requested shared component exists in `ps_shared_component_repos`;
- `project_key` is blank, or the requester has explicitly acknowledged the
  Phase 4 warning.

Report by editing a **single** sticky comment (find-by-marker, then update)
rather than appending. A checklist that mutates in place is readable weeks
later; twelve appended comments are not. Label transitions
(`onboarding` -> `onboarding:in-progress` -> `onboarding:done` /
`onboarding:failed`) give a queryable state for free.

## Phase 3 — repo creation via GitHub App

Use `actions/create-github-app-token@v3`, the same action the repo already uses
in `sync-template.yaml` and `jfrog-ps-bundle.yaml`, so there is one credential
story rather than two.

```yaml
- uses: actions/create-github-app-token@v3
  id: app
  with:
    client-id: ${{ vars.ONBOARDING_APP_CLIENT_ID }}
    private-key: ${{ secrets.ONBOARDING_APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}
```

App permissions needed:

| Scope | Level | Why |
| --- | --- | --- |
| Organization → Administration | write | create a repository in the org |
| Repository → Administration | write | set visibility, topics, `delete_branch_on_merge` |
| Repository → Contents | write | seed files, push the initial commit |
| Repository → Actions variables | write | `JF_NAME`, `JF_OIDC_PROVIDER`, `PREFERRED_RUNNER` |
| Repository → Secrets | write | only if per-repo secrets survive Phase 0 |
| Repository → Administration (members) | write | add the engagement lead |
| Repository → Pull requests | write | open the Terraform PR (Phase 5) |

Two constraints worth stating plainly, because they are the usual reason this
kind of automation fails on first run:

- **Creating from a template needs org-level repo-creation rights.** The
  `POST /repos/{template_owner}/{template_repo}/generate` endpoint is not
  covered by repository-scoped permissions. The App must be granted
  organisation administration, and the org must permit GitHub Apps to create
  repositories. A repo-scoped installation token will 403 here no matter what
  repository permissions it holds.

- **"Installed onto specific repos" and "creates repos in the org" are in
  tension.** Organisation-level permissions are installation-wide; they are not
  narrowed by the repository selection list. Restricting the installation to
  the template repo limits which *repositories* the token can touch, but the
  org administration permission still applies org-wide. So the installation
  selection is a useful blast-radius control for repo-scoped operations and the
  guard in Phase 2 is what actually prevents misuse. Do not treat the
  repository selection as a substitute for the guard.

  A cleaner alternative, if the org is willing: a second App with *only* org
  administration, whose private key lives as an environment secret on a
  protected `onboarding` environment that requires a reviewer. That converts
  the two-person rule into a platform control instead of workflow logic.

### Seed commit

After `generate`, push one commit that turns the generic template into this
customer's repo:

- `ps-bundle.deps.json` — the chosen shared components, pinned to the currently
  published version rather than `latest`, so a new repo is reproducible;
- `helm/` symlinks for the requested sizing and flavor, per
  `jfrog-helm-values`' own rules — read them, do not reimplement them here;
- `README.md` slug substitution;
- `CODEOWNERS` naming the engagement lead.

Explicitly **do not** seed `.gitmodules`, and delete `update-submodules.yaml`
from the new repo. A repo born on the artifact model should carry no trace of
the submodule model, or it inherits the exact hybrid the audit found.

## Phase 4 — the JFrog side

Per customer, the objects are: one `platform_group`, one `platform_permission`
scoped to `<slug>/**` of the bundles repo, one build-info permission, one
membership in the shared-read permission, and one
`platform_oidc_identity_mapping`. All five already exist as Terraform resources
in `modules/github-org/bundles.tf`, keyed off `local.bundle_repos`, which is
derived from `ps_engagement_repos`. **Adding one line to
`terraform.tfvars` creates all five.** Onboarding should not create them
individually.

### The identity mapping trap — read this before automating anything

> **The mapping must not carry a `project_key`.**
>
> Artifactory filters candidate identity mappings by the `project_key` in the
> token-exchange request **before** it orders the survivors by priority.
> `setup-jfrog-cli` forwards `JF_PROJECT` as `project_key`. The per-repo bundle
> mapping deliberately has no `project_key`, so it is only *eligible* when the
> exchange sends an empty one. If either side carries a project key that the
> other does not, the mapping is filtered out — priority never gets a chance to
> help — and the exchange falls through to whatever project-scoped mapping does
> match. For `ps-jfrog` that is the priority-8 org-wide `Contributor`, measured:
>
> ```text
> project_key=""         -> applied-permissions/groups:"<bundle group>"   ttl 1800
> project_key="ps-jfrog" -> applied-permissions/roles:ps-jfrog:"Contributor" ttl 60
> ```
>
> `Contributor` has no `DELETE_OVERWRITE_REPOSITORY`, so republishing a bundle
> over an existing path 403s, and the 60-second TTL expires before the job
> reaches build-info. That is the bug being fixed in `ej`, `gmit`, and
> `medtronic` right now.
>
> **This has two sides and onboarding must get both right.** Terraform owns the
> mapping side (no `project_key`, priority 5), which `bundles.tf` already does
> correctly. The *consumer* side is what onboarding controls: the workflow step
> that mints the bundle token must set `JF_PROJECT: ''` explicitly, and the repo
> must not carry a `JF_PROJECT` Actions variable that leaks into it.
>
> Three existing repos (`eq`, `mgm`, `ej`) have `JF_PROJECT=ps-jfrog` as a repo
> variable. Any onboarding automation that copies the current per-repo variable
> set from an existing engagement will reproduce this bug for every new
> customer. **Do not seed a `JF_PROJECT` variable.** If a customer genuinely
> needs one, it has to be set per-step on the steps that want project scoping
> and cleared on the step that mints the bundle token — which is precisely the
> shape the template's `jfrog-ps-bundle.yaml` now has.

A fair validation step: after onboarding, assert that the minted token's scope
contains `applied-permissions/groups` and its TTL is 1800, not 60. That single
assertion catches the entire class of failure, and it is the check the
engagement learned the hard way.

### Shared component read access

A bundle token is scoped to one group, and that group's permission target
covers only `<slug>/**`. So resolving `scripts-general-util/**` 403s unless the
group is also in the shared-read permission. `bundles.tf` handles this with
`platform_permission.bundle_shared_read`
(`ghc-ps-jfrog-bundle-shared-read`), which iterates every bundle group over
every entry in `ps_shared_component_repos` as `include_patterns`. Measured with
a real bundle-scoped token:

```text
GET api/storage/<bundles-repo>/ps-customer-template   -> 200
GET api/storage/<bundles-repo>/scripts-general-util   -> 403   (before the grant)
```

Because the permission is generated `for repo in local.bundle_repos`, a new
customer gets shared read automatically *when Terraform applies*. Via the API
it would be an easy thing to forget, and the failure is a 403 during dependency
resolution — the most confusing possible place for it to surface. This is a
strong argument for the Terraform-first path below.

Granting a customer a *new* shared component is one line in
`ps_shared_component_repos`, which widens the include patterns for every group
at once. If per-customer differentiation is ever needed, that resource has to
be split per group first.

> **Open question.** Should shared components be all-or-nothing? Today every
> bundle group reads every shared component. The issue form collects a
> per-customer checkbox, which today cannot be honoured. Either drop the
> checkbox or split the permission.

## Phase 5 — Terraform versus the API

Terraform is the source of truth, and the honest complication is that this
engagement accumulated five hand-applied Access API objects precisely because
`apply` was blocked. So "just use Terraform" is not a complete answer.

The recommendation:

1. **Onboarding opens a PR against `acrois-tf-oidc-bootstrap`** that adds
   `"ps-jfrog/ps-customer-<slug>"` to `ps_engagement_repos` in
   `terraform.tfvars`. That is the whole change — every JFrog object follows
   from it. The PR link goes into the sticky issue comment.

2. **Onboarding never writes to the JFrog platform via the API in the happy
   path.** Drift is worse than latency here: a hand-created group that
   Terraform later wants to create too produces an `apply` that fails on
   "already exists", which is exactly how `apply` got blocked in the first
   place. The five hand-applied objects from this engagement are the evidence.

3. **When `apply` is unavailable**, offer an explicit, labelled escape hatch
   rather than a silent fallback:
   - the workflow records the exact objects it *would* have needed in the issue;
   - a `/onboard --unblock` command, gated on the same team, creates them via
     the Access API **and** posts the matching `terraform import` commands into
     the issue;
   - the issue stays open with an `onboarding:drift` label until the import has
     landed.

   The rule is that every hand-applied object leaves behind the command that
   reconciles it. The reason the five objects hurt is not that they were
   hand-made; it is that nothing recorded how to adopt them.

> **Open question.** Can onboarding run `terraform plan` in CI against this
> workspace to prove the one-line change is clean before merging? If not, the
> PR is a hope rather than a verification, and the unblock path becomes the
> common case rather than the exception.

## Phase 6 — runner assignment

Set `PREFERRED_RUNNER` only when the form asks for a self-hosted pool, and
verify the label has an online runner *before* setting it. The cost of getting
this wrong is not a fast failure: a job queued against an absent label sits for
24 hours and is then auto-cancelled, which reads as `cancelled` in the run list
and is easy to mistake for someone pressing a button. That is what happened to
`ej`, `gmit`, and `mgm` on 2026-09-07 — jobs created at 13:2x and cancelled at
13:2x the following day.

Prefer `ubuntu-latest` as the default and treat self-hosted as an opt-in for
engagements that actually need network reachability into a customer
environment.

## Phase 7 — idempotency and rollback

Onboarding is a multi-system write, so it will fail halfway. Design for it:

- **Key everything off the slug.** Group names, permission names, mapping
  names, repo name, and bundle subfolder are all derived, so a re-run targets
  the same objects instead of creating parallel ones.
- **Make each step check-then-act.** Repo exists -> skip creation and continue
  with configuration. Variable already set to the wanted value -> skip. Terraform
  PR already open for this slug -> update it rather than opening a second.
- **Persist state in the issue, not in the workflow.** The sticky comment's
  checklist *is* the state file. A re-run reads it and resumes. This avoids
  needing external storage and keeps the audit trail where a human will look.
- **Rollback is deliberate, not automatic.** A half-created repo may already
  contain customer work. A `/onboard-rollback` command, same authorisation,
  that deletes the repo only if it has no commits beyond the seed and closes the
  Terraform PR. Anything beyond that is a human decision.

> **Open question.** Should a failed onboarding leave the repo in place or
> delete it? Leaving it risks someone using a half-configured repo; deleting it
> risks destroying work. Leaning toward leaving it with a prominent
> `README.ONBOARDING-INCOMPLETE.md` and an `onboarding:failed` label.

## Phase 8 — verification that the repo actually works

Assertions are worthless here; this engagement found every real bug by running
the sequence. Onboarding should finish by dispatching a verification run in the
new repo and reporting the result onto the issue. The sequence, in order,
because each step catches a different failure:

1. **Resolve dependencies** (`ps_bundle_resolve`). Proves the identity mapping
   is reachable, the token carries the bundle group, and shared-read works.
   This is where a 403 on `scripts-general-util/**` shows up.
2. **Publish the bundle.** Proves write access to `<slug>/**`.
3. **Republish over the same path.** Proves the token has
   `DELETE_OVERWRITE_REPOSITORY` — that is, proves the exchange landed on the
   bundle mapping and not on `Contributor`. A first publish succeeds under both;
   only the second one discriminates. **This step is the whole point.**
4. **Publish build-info.** Proves the TTL is 1800 and not 60, since build-info
   lands minutes into the job, and proves the build project is unset so the
   record goes to the global build-info repo rather than a project-owned one.
5. **Assert the token spec directly** — scope contains
   `applied-permissions/groups`, `expires_in` is 1800.

Only after all five pass should the issue close as `onboarding:done`.

## What this proposal deliberately does not do

- **It does not migrate existing repos.** The audit shows `sync-template`
  cannot carry the submodule-to-artifact migration: the merge keeps
  `.gitmodules` and the gitlink while adding `ps-bundle.deps.json`, and commits
  conflict markers into `.envrc` and two workflow files. Migration is a
  separate, mostly-manual piece of work.
- **It does not replace `sync-template`.** Onboarding creates repos correctly;
  keeping them current is still sync's job, and sync needs its push bug fixed
  (Phase 0) before it is worth building on.
- **It does not create JFrog objects directly** in the happy path, for the
  drift reasons in Phase 5.

## Suggested order of work

| Order | Work | Why first |
| --- | --- | --- |
| 1 | Org-level App credentials | Unblocks six repos immediately; removes a per-repo onboarding step |
| 2 | Fix `sync-template` push lease + `delete_branch_on_merge` | Sync is latched everywhere it has ever run |
| 3 | Issue form + guarded dispatcher, dry-run only | Get the parsing and authorisation right with no writes |
| 4 | Terraform PR automation | The single highest-value write, and the least risky |
| 5 | Repo creation via App | Needs org permission negotiation; do it once the rest works |
| 6 | Verification workflow | Can be built and run against existing repos before onboarding exists |

Steps 1, 2, and 6 have value even if IssueOps is never built. That ordering is
intentional.
