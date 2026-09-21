# Customer repo migration runbook

How to move a `ps-customer-*` repository off the `scripts-general-util` git
submodule and onto the `ps-bundle.deps.json` artifact model, and then stop it
conflicting with this template forever after.

Measured on **`ps-jfrog/ps-customer-gco`** (the pilot), which was migrated end to
end in [#1](https://github.com/ps-jfrog/ps-customer-gco/pull/1) and
[#2](https://github.com/ps-jfrog/ps-customer-gco/pull/2). Numbers and failure
modes below are observed, not estimated, except where labelled as an estimate.

## The shape of the job

It is two unrelated problems that happen to land on the same repositories, and
they must not be mixed into one commit.

**Phase A — structural migration.** Fully scripted, offline, idempotent. Removes
the submodule and declares the dependency. Takes minutes and has no judgement in
it.

**Phase B — divergence reconciliation.** The actual work. These repos were forked
from the template at different times and drifted. Because template-derived repos
have *unrelated histories*, `git merge --allow-unrelated-histories` treats every
drifted file as an **add/add conflict**, so `Sync Template` aborts (correctly)
until the drift is reconciled. Phase A does not help with this at all.

Keep them as separate PRs. Phase A is reviewable at a glance; Phase B needs a
reviewer to actually read hunks.

### Scriptable vs. human judgement

Automate the first column. Do not automate the second — every item there can
destroy engagement work, and the failure is silent.

| scriptable | needs a human |
| --- | --- |
| the whole of Phase A (`migrate-from-submodules.sh`, idempotent and offline) | deciding whether a hunk is template-managed or customer-specific |
| every Phase A verification assertion | whether a repo's extra `.zipignore` / `.gitignore` entries are still needed |
| counting sync conflicts before and after | whether a `.tool-versions` delta is drift or a deliberate engagement pin |
| listing the divergent set and the ONLY-IN-REPO set | resolving a file that cannot become byte-identical |
| copying a template blob and checking byte-identity | reading a `README` for customer-facing promises before overwriting it |
| detecting the known workflow bugs by `grep` | confirming a red check is provisioning, not a migration defect |

The bulk of a repo is mechanical. The judgement is concentrated in maybe five
files, and it is the same five files every time — which is why the first repo
costs several times what the last one does.

## Phase A — structural migration

### Run it

Prefer the workflow when the repo already has it:

> Actions → **Migrate From Submodules** → Run workflow → type `owner/name` to
> confirm → optionally tick **dry run** first.

Otherwise (or for a repo that has never synced and has no such workflow) run the
same script offline from a template checkout against a clone of the target:

```sh
git clone --no-recurse-submodules https://github.com/ps-jfrog/ps-customer-<slug>.git
cd ps-customer-<slug>
git checkout -b chore/migrate-from-submodules

TPL=/path/to/ps-customer-template
"$TPL/.github/scripts/migrate-from-submodules.sh" --dry-run --template-dir "$TPL"
"$TPL/.github/scripts/migrate-from-submodules.sh" --template-dir "$TPL"
```

Do not reimplement any of this, and do not hand-deinit the submodule — doing it
by hand leaves the `.gitmodules` entry, the gitlink or the `.zipignore`
exclusions behind, which puts the repo on *both* dependency models at once.

Pass `--template-dir`. Without it the script writes a `latest` pin and skips
installing `.envrc.d/ps_bundle_resolve`; with it the repo inherits the template's
exact pin and resolver.

### Capture the baseline first

The one irreversible-looking thing is the `.envrc.d/*` symlinks, so record them
before you start and diff after:

```sh
git ls-files -s .envrc.d/ | tee /tmp/symlinks-before.txt
git ls-files -s | awk '$1 == "160000"'   # gitlinks, before
```

### Verify

```sh
[ -f .gitmodules ] && echo "FAIL: .gitmodules present"
git ls-files -s | awk '$1 == "160000" && $4 == "scripts-general-util"'   # must be empty
[ -d .git/modules/scripts-general-util ] && echo "FAIL: stale private gitdir"
[ -f ps-bundle.deps.json ] || echo "FAIL: no manifest"
grep -qxF '/scripts-general-util/' .gitignore && grep -qxF '/deps/' .gitignore
[ -f .github/workflows/update-submodules.yaml ] && echo "FAIL: bumper still present"

diff <(git ls-files -s .envrc.d/) /tmp/symlinks-before.txt   # only ps_bundle_resolve may be added
bash -n .envrc
for f in .github/workflows/*.yaml; do
  python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" || echo "FAIL: $f"
done

"$TPL/.github/scripts/migrate-from-submodules.sh" --template-dir "$TPL"   # must say "nothing to do"
"$TPL/.github/scripts/check-tree-sanity.sh"
git status --short                                                         # must be empty after commit
```

On the pilot every check passed, all six symlink blob SHAs were unchanged, and
the re-run reported `Already on the bundle dependency model; nothing to do.`

### Repos with more than one submodule

Six of the ten remaining repos vendor other submodules (`jfrog-helm-values`,
`jpd-compose`, `ps-jfrog-runner`, `tf-jfrog-repo-factory`, …). **Those must
stay.** The script converts only `scripts-general-util`: it removes just that
`.gitmodules` section and keeps the file when anything else remains, and strips
only that name from `.zipignore`.

This was verified on a throwaway local clone of `pnc` (never pushed):
`jfrog-helm-values` kept its gitlink, its `.gitmodules` section and its
`.zipignore` exclusions, and the `helm/*.yaml` symlinks into it still resolved.

Confirm it per repo anyway, since this is the step that would silently destroy
engagement work:

```sh
git ls-files -s | awk '$1 == "160000"'   # every submodule EXCEPT scripts-general-util
ls -l helm/ 2>/dev/null                  # symlinks into other submodules still resolve
```

## Phase B — divergence reconciliation

### Measure before you touch anything

Replay exactly what `sync-template.yaml` does, and count:

```sh
git remote add template /path/to/ps-customer-template   # or the https URL
git fetch template main
git checkout -b conflict-probe
git merge FETCH_HEAD --no-commit --no-ff --allow-unrelated-histories
git ls-files --unmerged | awk '$1 != "160000" {print $4}' | sort -u   # the conflict set
git merge --abort && git checkout - && git branch -D conflict-probe
```

This same command is the acceptance test at the end. Record the count now.

On the pilot this was **6**: `.envrc`, `README.md`, `.gitignore`,
`jfrog-ps-bundle.yaml`, `share-ps-bundle.yaml`, `sync-template.yaml`.
`.zipignore` had been in that set and dropped out because Phase A fixed it.

A faster equivalent that also tells you what is safe to adopt wholesale:

```sh
# files present in both but with different content == the future conflict set
comm -12 <(git ls-files | sort) <(cd "$TPL" && git ls-files | sort) | while read -r f; do
  [ "$(git rev-parse ":$f")" != "$(cd "$TPL" && git rev-parse ":$f")" ] && echo "$f"
done

# files the repo has and the template does not == engagement work; NEVER touch
comm -23 <(git ls-files | sort) <(cd "$TPL" && git ls-files | sort)
```

That second list is the single best predictor of how hard a repo will be. The
pilot's was **empty**. No other repo's is.

### The classification heuristic actually used

For each hunk, ask **"if the next engagement hit this same line, would it want
the same value?"**

**Template-managed — adopt the template's version wholesale.** In practice, a
hunk is template-managed if *all* of these hold:

- it contains no literal customer name, hostname, URL, token, secret ref, TLS
  material, sizing number, or replica/resource count;
- any site value it does mention is already read indirectly, through
  `vars.*` / `secrets.*` / `${{ env.* }}` rather than hardcoded;
- the difference is explainable as "this repo forked before that fix landed" —
  a comment rewrite, a bug fix, a new step, a reordering.

**Customer-specific — keep the repo's version.** URLs, secret references, sizing
deltas, TLS, customer naming, and engagement tooling pins.

The decisive shortcut: **site-specific configuration already lives in GitHub repo
variables**, not in files. `JF_NAME`, `JF_PROJECT`, `JF_URL`, `APP_CLIENT_ID`,
`JF_OIDC_PROVIDER`, `JFROG_CLI_REMOTE`, `JFROG_CLI_VERSION` are all read through
`vars.*` / `secrets.*` by both the template's and the customer's copy of every
workflow. That mechanism already exists — **do not invent a new one, and do not
add a site values file.** If a hunk's only "customer-specific" content is one of
those names, it is template-managed.

So the reconciliation is usually "adopt the template's file" plus a short list of
genuine exceptions, not a hunk-by-hunk merge.

Two worked examples from the survey, on the same filename, classified opposite
ways:

- `gco`'s `.tool-versions` was byte-identical to the template → nothing to decide.
- `mgm`'s `.tool-versions` adds `opentofu`, `sops`, `age` and pins newer
  `terraform`/`golang` than the template; `ks`'s adds `helmfile`. Those are
  engagement tooling — **customer-specific, keep them.** Blindly adopting the
  template here would break the engagement's tooling.

### The pilot's classification, in full

Every hunk in all six files was template-managed. Not one carried a
customer-specific value, so nothing had to be relocated anywhere.

| file | hunks | verdict | why |
| --- | --- | --- | --- |
| `.envrc` | 4 | template-managed | comment rewrite; `zip` "name not matched" guard; `_show_deps_summary`; resolve-before-build wiring |
| `README.md` | 4 | template-managed | toolbox-based customer instructions + dependency docs. The copy here still said `PS_BUNDLE_NAME="template"` — it had never been customised |
| `.gitignore` | 1 | template-managed | the migration script wrote a one-line comment where the template had two |
| `jfrog-ps-bundle.yaml` | 6 | template-managed | annotated-tag peel; drop App token / SSH known_hosts / `submodules: true` from checkout; add `Setup Bundle Reader`; `JF_PROJECT: ''` on token minting; `bundle-writer` server ids; build-info env |
| `share-ps-bundle.yaml` | 4 | template-managed | drop the hardcoded `ps-jf` step override; derive server id from `JF_PROJECT` |
| `sync-template.yaml` | many | template-managed | predates the abort-on-conflict-markers guard |

Because nothing was customer-specific, the pilot could adopt the template's copy
of all six files *and* add the six template-only files, leaving its tracked tree
byte-identical to the template. **That shortcut is specific to `gco`** — it had
zero files of its own. Everywhere else, adopt per file and leave the repo's own
files alone.

### Adopting a file from the template

Copy out of the template's index rather than its worktree, so you get the
committed blob and not someone's local edit:

```sh
for f in .envrc README.md .github/workflows/jfrog-ps-bundle.yaml; do
  (cd "$TPL" && git cat-file blob ":$f") > "$f"
  chmod "$( cd "$TPL" && git ls-files -s "$f" | awk '{print ($1 == "100755") ? "755" : "644"}' )" "$f"
  git add "$f"
done
```

Then confirm byte-identity by blob SHA, which is stronger and faster than `diff`:

```sh
[ "$(git rev-parse ":$f")" = "$(cd "$TPL" && git rev-parse ":$f")" ] && echo IDENTICAL
```

### Workflow fixes to confirm while you are in there

Check rather than assume — on the pilot, three of the "known" issues turned out
not to apply, and only checking revealed that.

| issue | how to detect | pilot |
| --- | --- | --- |
| `BUNDLE_REPO` falls back to the nonexistent `ps-bundles` (live repo is `ps-jfrog-ps-bundles`) | `grep 'BUNDLE_REPO:' .github/workflows/*.yaml` — a trailing `\|\| 'ps-bundles'` is the bug; `\|\| ''` is correct | not present |
| missing `Create Scoped Token` step | `grep -c 'name: Create Scoped Token' .github/workflows/jfrog-ps-bundle.yaml` | present already |
| commented-out build-info step | `grep -E '^\s+- name: Build Information' .github/workflows/jfrog-ps-bundle.yaml` | present already |
| `JF_PROJECT` not cleared on token-minting steps | `JF_PROJECT: ''` must appear under **both** `Setup Bundle Reader` and `Create Scoped Token` | was missing; fixed by adopting the template |

The `JF_PROJECT: ''` one matters and is easy to get wrong. `setup-jfrog-cli`
forwards `JF_PROJECT` as `project_key` on the OIDC exchange, and Artifactory
filters candidate identity mappings by `project_key` **before** ordering them by
priority. The per-repo bundle mapping carries no `project_key`, so any non-empty
value makes it ineligible and the exchange silently falls through to the org-wide
project `Contributor` mapping — which has no `DELETE_OVERWRITE_REPOSITORY` (so
republishing over an existing path fails) and a 60s TTL (which expires mid-job,
before build-info publishes).

**Never add a `JF_PROJECT` repo variable to fix this.** The workflow-level
`JF_PROJECT` is needed to derive `BUNDLE_REPO`; the fix is the empty *step-level*
override on the token-minting steps only.

### Prove it

```sh
git merge FETCH_HEAD --no-commit --no-ff --allow-unrelated-histories
git ls-files --unmerged | awk '$1 != "160000" {print $4}' | sort -u | wc -l   # target: 0
git diff --cached --stat                                                      # ideally empty
```

Pilot result: **6 → 0**, merge exiting 0 with no markers and no staged changes.
Both index trees hashed to `38f3962d9689cc9e16bbe8815275d01ed5719a9a`, so
`git diff --quiet FETCH_HEAD` is clean and sync now short-circuits at its "Tree
identical to template" check without even attempting a merge.

Zero staged changes is the `gco` outcome and will not generalise. For a repo with
its own files, **0 conflicts with a non-empty diff is the correct result** — sync
will bring template updates in as a clean merge.

### When a file cannot reach zero: land one merge, and mind the ordering

For a repo whose `.zipignore` / `.gitignore` legitimately keep customer-specific
entries, byte-identity is not available and the add/add conflict cannot be
reconciled away. That is fine, because **the add/add conflict is a one-time
artifact of unrelated histories.** Resolve it by hand once and *commit the merge*
— the merge commit gives the two repos a common ancestor, and every later sync is
an ordinary 3-way merge.

Verified on a local `pnc` clone: after committing one hand-resolved sync merge,
`git merge-base HEAD FETCH_HEAD` resolved to the template commit, and no
`--allow-unrelated-histories` was needed again.

**Where you put the customer lines decides whether this actually helps**, and
getting it wrong is silent. Measured on that same clone, against a simulated
later template change that appended a line to `.zipignore`:

| customer block placed… | next sync |
| --- | --- |
| appended after the template's content | **conflicts** — both sides append at EOF, so every future template addition collides there forever |
| placed *above* the template's block, template content kept verbatim as the tail | **0 conflicts** — the template's append lands cleanly and the customer lines survive |

So build these files as *customer block first, template block verbatim last*:

```sh
{
  echo "# Customer-specific exclusions (other submodules, local tooling)."
  cat customer-lines.txt
  echo ""
  (cd "$TPL" && git cat-file blob ":.zipignore")
} > .zipignore
```

Union the two sides rather than picking one — dropping the template's entries
loses bundle hygiene, dropping the customer's ships other submodules' contents
inside the bundle.

## End-to-end verification

Structural checks do not catch token-scoping bugs. Only this sequence does, and
it is what caught every real bug in this engagement:

1. **the bundle publishes** — push a CalVer tag on the default branch, watch
   `Build JFrog PS Engagement Bundle`;
2. **a republish over the same path succeeds** — this is the
   `DELETE_OVERWRITE_REPOSITORY` test, and it is the one that catches a
   mis-scoped token. A plain re-run can upload byte-identical content and pass
   vacuously, so make the second publish carry **different** content (touch a
   tracked file) — an A/B, not a repeat;
3. **`ps_bundle_resolve` actually downloads `scripts-general-util`** — needs a
   bundle-reader token and a per-repo JFrog identity mapping to exist;
4. **build-info publishes** — `jf rt bp` at the end of the run.

Never print raw tokens. Decode and print claim fields only (`groups`, `scope`,
`exp`), and delete any probe artifact you upload.

All four passed on the pilot, once provisioning caught up:

| proof | evidence |
| --- | --- |
| publishes | `Uploading bin/output.zip to ps-jfrog-ps-bundles/ps-customer-gco/v2026.37.05/` |
| republishes over the same path, differing content | the same `v2026.37.05/` path again one commit later, that time carrying `docs/customer-repo-migration-runbook.md` |
| resolves the dependency | `scripts-general-util v2026.36.05.3 -> scripts-general-util/ (downloaded)`, then its files appear in the archive listing |
| build-info | `Build info successfully deployed … buildRepo=artifactory-build-info` |

### Getting a real republish without a contrived probe

CalVer moves the **unsuffixed** day tag (`2026.37.05`) to the newest commit on
the default branch, while `2026.37.05.N` is pinned per commit. So the bundle path
`v<unsuffixed>` is republished with genuinely different content on every
default-branch commit that day — that *is* the A/B, for free, with no throwaway
artifact to clean up afterwards.

Confirm it before trusting it:

```sh
git ls-remote --tags origin | grep -v '\^{}'   # unsuffixed tag should track the newest commit
```

Do not "test" republish by re-running the same workflow on the same commit: same
tree, same exploded content, so it can pass without ever exercising
`DELETE_OVERWRITE_REPOSITORY`.

### Provisioning prerequisites — check these before blaming the migration

A migrated repo still needs repo variables before any of the four steps above
can run. Confirm first:

```sh
gh api repos/ps-jfrog/ps-customer-<slug>/actions/variables --jq '.variables[] | "\(.name)=\(.value)"'
```

A fully provisioned repo looks like the template: `JF_NAME`, `JF_PROJECT`,
`JFROG_CLI_VERSION`, `JFROG_CLI_REMOTE`, `JF_OIDC_PROVIDER`, plus an
`APP_CLIENT_ID` variable or secret.

On the pilot, `JF_NAME`, `JFROG_CLI_REMOTE` and `JFROG_CLI_VERSION` were enough
to get all four checks passing — `JF_PROJECT` was never set and turned out not to
be required, because `ps_bundle_upload` derives the bundle repository itself
(it published to `ps-jfrog-ps-bundles/ps-customer-gco/…` with `BUNDLE_REPO`
empty). `JF_PROJECT` is still needed by `share-ps-bundle.yaml`, which fails fast
with an explicit error when `BUNDLE_REPO` is empty.

`APP_CLIENT_ID` is the one that stays blocking: without it `Sync Template` cannot
mint an App token and fails on its first step. There is **no** org-level
`ORG_APP_CLIENT_ID` to fall back on, so every unprovisioned repo has a
permanently red `Sync Template` regardless of how well it is migrated.

### Expect to be blocked twice, not once

Two independent blockers stacked on the pilot, and the second was invisible until
the first was cleared:

1. no `JFROG_CLI_VERSION` → CLI download 500s on the `[RELEASE]` placeholder;
2. once that was provisioned, the download succeeded and the **31-byte
   `JFROG_CLI_ENCRYPTION_KEY` fallback** became the next error.

Both fail in the same step (`Setup JFrog CLI`) with completely different causes,
so re-read the log after clearing each one rather than assuming the step is
"still failing for the same reason".

That second one was a genuine template defect, found only because the pilot was
driven all the way to green. It affected **7 of 11 repos** — every repo without
the `JFROG_CLI_ENCRYPTION_KEY` secret (`gco`, `ks`, `pnc`, `asr`, `allstate`,
`nw`, `gmit`) — and had been failing their nightly `Test OIDC to JFrog` schedule
for months. It is fixed template-side now, so the remaining ten inherit the fix,
but check that each one is actually on the current workflows:

```sh
grep -h 'JFROG_CLI_ENCRYPTION_KEY:' .github/workflows/*.yaml   # fallback must be 32 bytes
```

## Per-repo failure modes hit, and how to tell them apart

Everything below fails on a workflow's **first step**, before any migrated code
executes. That is the tell: a genuine migration defect fails in the middle, in a
step that touches `.envrc`, `ps_bundle_resolve` or `ps_bundle_upload`.

| symptom | cause | migration defect? |
| --- | --- | --- |
| `Setup JFrog CLI`: `Downloading JFrog CLI from .../v2/[RELEASE]/... Unexpected HTTP response: 500` | no `JFROG_CLI_VERSION` variable, so it defaults to `latest` and the action requests the `[RELEASE]` placeholder through the `ps-jf-prod-cli` remote | **no** — provisioning |
| `Setup JFrog CLI`: `cannot encrypt config: Wrong length for master key. Key should have a length of exactly: 32 bytes` | the template's `JFROG_CLI_ENCRYPTION_KEY` fallback was 31 bytes. Fixed template-side; a repo still on an older copy of the workflows will hit it | **no** — template defect, now fixed |
| `BUNDLE_REPO` resolves empty, nothing to publish to | no `JF_PROJECT` variable | **no** — provisioning |
| `create-github-app-token`: `The 'client-id' ... must be set to a non-empty string` | repo has the `APP_PRIVATE_KEY` secret but no `APP_CLIENT_ID` variable, and there is **no org-level `ORG_APP_CLIENT_ID`** to fall back on. This fails `Sync Template` on every unprovisioned repo | **no** — provisioning |
| checkout fails authenticating an SSH submodule URL with the App token | `.gitmodules` uses `git@github.com:` and the App token cannot drive SSH. Migration **removes** this for `scripts-general-util`; a repo with other submodules still needs their URLs dealt with | fixed by migration for `scripts-general-util` only |
| release matrix resolves empty, nothing ever publishes | `git rev-parse "$ref"` on CalVer's *annotated* tags yields the tag object sha, never `GITHUB_SHA`. Needs the `^{commit}` peel | yes — fixed in the template |
| `Sync Template` aborts: "merged tree is not safe to commit" | working as designed: Phase B is not done, or the repo is still submodule-era | no |

Confirming a failure is external is a two-command A/B — diff the resolved env of
the failing run against a run that passes in this template repo:

```sh
gh run view <failing-id> --repo ps-jfrog/ps-customer-<slug> --log \
  | grep -E 'JFROG_CLI_VERSION:|JF_PROJECT:|BUNDLE_REPO:|Downloading JFrog CLI' | sort -u
```

Also worth knowing: `push` triggers on `branches: ['**']`, so pushing a migration
branch runs **CalVer Tagging**, which creates branch-variant tags like
`2026.37.05-chore-migrate-from-submodules`, which in turn makes the bundle
workflow try to publish them. Those are pilot litter — delete them after merging:

```sh
git push origin --delete "refs/tags/<calver-branch-variant-tag>"
```

## Effort estimate for the remaining ten

Phase A is ~10 minutes wall-clock and essentially risk-free. All the variance is
in Phase B, and it tracks one number: **how many files the repo has that the
template does not** (`ONLY-IN-REPO` below) — that is engagement work you must
read around rather than adopt.

Measured across all ten (read-only shallow clones):

Conflict counts below were **measured**, not predicted: each repo was
shallow-cloned locally, Phase A was run, and the sync merge was replayed before
and after. Nothing was pushed.

| repo | submodules | conflicts before A | after A | ONLY-IN-REPO | notable |
| --- | --- | --- | --- | --- | --- |
| `asr` | 1 | 7 | **5** | 3 | cleanest; closest to the pilot |
| `allstate` | 1 | 7 | **5** | 3 | cleanest; closest to the pilot |
| `nw` | 1 | 7 | **5** | 26 | Phase A clears both ignore files |
| `medtronic` | 1 | 6 | **5** | 10 | **no `sync-template.yaml`**; `ps-bundles` bug; no `Create Scoped Token`; no build-info step; `jfrog-oidc-test.yaml` also drifted |
| `gmit` | 4 | 7 | **6** | 11 | `ps-bundles` bug; no `Create Scoped Token`; no build-info step; `jfrog-oidc-test.yaml` also drifted |
| `eq` | 6 | 6 | **6** | 16 | six submodules to preserve |
| `mgm` | 5 | 7 | **7** | 9 | customer `.tool-versions` (opentofu/sops/age) |
| `ej` | 3 | 7 | **7** | 51 | checkout currently fails on the SSH submodule URL |
| `pnc` | 2 | 8 | **8** | 20 | stale copy of `consult-submodule-rules.mdc` |
| `ks` | 4 | 8 | **8** | **364** | by far the largest; customer `.tool-versions` (helmfile) |

All ten still carry the `scripts-general-util` gitlink and a `.gitmodules`, none
has `ps-bundle.deps.json`, and all eight that have `update-submodules.yaml` are
failing it on every scheduled run.

The divergent sets are near-identical: `.envrc`, `README.md`,
`sync-template.yaml`, `jfrog-ps-bundle.yaml`, usually `share-ps-bundle.yaml`.
That repetition is what makes the work cheap after the first repo.

Note what Phase A does and does not clear, because it is easy to over-claim.
`.zipignore` and `.gitignore` drop out of the conflict set **only** for repos
whose ignore files contain nothing but the template's entries plus the
`scripts-general-util` exclusions — `asr`, `allstate`, `nw` and (for
`.gitignore`) `gmit`, `medtronic`. Everywhere else both files keep diverging,
and **correctly so**: those extra lines exclude the repo's *other* submodules
and local tooling (`jfrog-helm-values`, `.cursor`, `.boost`) from the bundle.
They are customer-specific — keep them, and expect those two files to stay in
the conflict set permanently.

Because the divergent set repeats, the classification is done **once** and then
reapplied. Budget for the first repo, not the tenth.

| tier | repos | per repo | why |
| --- | --- | --- | --- |
| Easy | `asr`, `allstate` | **45–60 min** | single submodule, almost no repo-specific content, identical divergent set |
| Moderate | `mgm`, `eq`, `nw`, `pnc` | **1.5–2.5 h** | multiple submodules to preserve; `mgm` needs its `.tool-versions` kept; `pnc` has a stale rule file |
| Harder | `gmit`, `ej` | **2.5–4 h** | `gmit` predates three workflow fixes, so its bundle workflow is a rewrite not a merge, plus 4 submodules; `ej` has 51 files of engagement work and a checkout that fails today, so it cannot be verified green until the SSH submodule URLs are also resolved |
| Hardest | `medtronic`, `ks` | **4–6 h** | `medtronic` has no `sync-template.yaml` at all — it must be **installed** from the template rather than merged, and it predates the same three workflow fixes as `gmit`; `ks` has 364 repo-specific files, so every adopt-wholesale decision needs checking against real engagement content |

**Total: roughly 20–30 engineering hours**, plus provisioning, which is not in
these numbers and is the current hard blocker. Front-load `asr` or `allstate` to
bank the reusable classification cheaply.

Two things that will change the estimate materially, in opposite directions:

- Provisioning every repo's variables first turns the four end-to-end checks
  from "blocked" into real verification. Without it, every repo lands with the
  same red checks the pilot did and the token-scoping fix stays unproven per
  repo. The known-good set, measured on `ps-customer-bofa` and then on
  `ps-customer-gco`, is `JF_NAME`, `JFROG_CLI_REMOTE`, `JFROG_CLI_VERSION`,
  `PREFERRED_RUNNER` and `BUNDLE_REPO`.

  Two of those are easy to get wrong in opposite directions:

  - **Never set `JF_PROJECT`.** Artifactory filters candidate OIDC identity
    mappings by `project_key` *before* applying priority, so any non-empty value
    makes the per-repo priority-5 mapping ineligible and the exchange falls
    through to an org-wide `Contributor` that lacks
    `DELETE_OVERWRITE_REPOSITORY` and expires in 60 seconds. This is the single
    defect that caused most of the pilot's failures.
  - **Always set `BUNDLE_REPO` explicitly**, to `ps-jfrog-ps-bundles`. The
    bundle workflow derives it from `JF_PROJECT`, so a repo that correctly has no
    `JF_PROJECT` computes an empty value and fails with `BUNDLE_REPO is empty`.
  - `APP_CLIENT_ID` is **no longer wanted** on a customer repo. The per-repo
    `sync-template.yaml` that needed it is retired; the template fans the sync
    out and holds the only App credential, so a customer repo needs no
    credentials at all.
- `medtronic` was identified by file fingerprint, not by a template marker. Treat
  its file provenance as unverified and diff it fully before adopting anything.

## Flagged for a human decision

- **`ks`, 364 repo-specific files.** Adopt-per-file only. Do not take the
  byte-identical shortcut the pilot used.
- **`medtronic` has no `sync-template.yaml`.** Installing it starts a weekly
  unattended job against a repo nobody has synced before. Reconcile first, then
  install the workflow, so its first run is a no-op rather than a conflict.
- **`ej` cannot go green from migration alone.** Its other submodules
  (`ps-jfrog-runner`, `workflow-example`) keep `git@github.com:` URLs that the
  App token cannot authenticate.
- **`mgm` and `ks` `.tool-versions`.** Genuinely customer-specific. Overwriting
  them from the template would downgrade engagement tooling.
- **`ps-customer-valero` needs no migration, and is not in the tiering above.**
  It is a 12th derived repository that earlier audits missed, generated from the
  template on 2026-09-16 — after the artifact-dependency migration — so it has
  `ps-bundle.deps.json`, no `.gitmodules` and no `scripts-general-util` gitlink.
  There is nothing to migrate: it sits *below* the Easy tier at zero migration
  hours. What it lacks is provisioning. It has **no repo variables at all** and
  is **absent from `ps_engagement_repos`**, so it has no group, no bundle
  permission and no OIDC identity mapping. It is also dormant — one `Initial
  commit`, `pushed_at` equal to `created_at`, no engagement content — and every
  one of its red checks is an `ubuntu-latest` billing rejection, which currently
  masks the provisioning gap rather than revealing it.

  The decision is therefore not "when do we migrate it" but "is this engagement
  real": provision it like `bofa` (Terraform entry, then the five variables) or
  retire the repository. Do not pick the third option of leaving it as-is — it
  is a repo generated via `/generate`, so it has no merge base with the template
  and will turn into an aborting sync target on the first template change that
  modifies rather than adds to a shared file.

## Where this meets onboarding

Migration and onboarding are the two halves of the same fleet problem and they
do not overlap in work, only in outcome. `docs/onboarding-issueops-proposal.md`
covers repositories that do not exist yet; this runbook covers the ten that do
and are on the wrong dependency model.

Two connections worth knowing:

- **The fan-out sync reports, it does not migrate.** A repository still on the
  submodule model aborts with `aborted-conflict` and a message naming the
  `Migrate From Submodules` workflow. That abort is the tree-sanity guard
  working, not a defect, and it is the signal that this runbook applies.
- **Phase B is what buys a merge base.** Until one sync merge is committed, a
  derived repository shares no history with the template and every drifted file
  merges as an add/add conflict. Onboarding sidesteps this for new repositories
  by seeding them with the template's actual history; for existing ones, only
  landing the first merge does it.

