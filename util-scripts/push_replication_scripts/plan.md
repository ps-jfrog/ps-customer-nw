# Push Replication Migration Plan

## Goal

Migrate push replication configurations from one Artifactory JPD (jpd1) to another
(jpd2) one at a time, with backup/restore support. The workflow per repo is:

1. Back up all push replication configs from jpd1
2. For each repo (one at a time):
   a. Disable the replication on jpd1
   b. Restore the exact same config on jpd2 (from the backup)
   c. Trigger an immediate replication on jpd2 to verify
   d. Confirm the run succeeded, then move to the next repo

---

## Task 1 — Add `backup` command to `push_replication_configure.py`

### What it does
- Calls `GET /artifactory/api/replications` (no repo key) to auto-discover **all**
  repos with push replications configured on the source JPD — no pre-populated
  repo list needed.
- Saves each repo's config as `<backup-dir>/<repo>.json`, preserving the exact
  payload (cron expression, sync flags, URL, username, enabled state, etc.).
- Accepts `--backup-dir` (default: `replication_backup/`) to control where files
  are written.
- Supports `--repo` to back up a single repo instead of all.
- Supports `--dry-run` (lists what would be saved, no files written).

### CLI shape
```bash
python3 push_replication_configure.py backup \
  --source-url https://jpd1.jfrog.io \
  --access-token $JPD1_TOKEN \
  [--backup-dir replication_backup/] \
  [--repo my-repo-local] \
  [--dry-run]
```

### DRY / code-reuse notes
- Reuse existing `get_headers(config)` for authentication.
- Reuse existing `_resolve_path()` for backup-dir path resolution.
- Add a shared internal helper `_fetch_replication_config(repo_key, config) -> dict|list|None`
  that wraps the `GET /artifactory/api/replications/{repo}` call — this replaces
  the inline logic currently duplicated across `get_replication_status()`,
  `Get_Replication_Configuration.py`, and `disableAllReplication.sh`.
- Add a shared internal helper `_discover_replicated_repos(config) -> List[str]`
  that calls `GET /artifactory/api/replications` (no repo key) and returns the
  list of repo keys that have a replication configured. Used by `backup` (and
  potentially by future bulk operations).

---

## Task 2 — Add `restore` command to `push_replication_configure.py`

### What it does
- Reads a backed-up JSON file (or all files in `--backup-dir`) and `PUT`s the
  payload verbatim to the target JPD, preserving the exact original config
  (cron, sync flags, enabled state, etc.).
- Rewrites the `url` field in the payload to point to the target JPD (since the
  replication endpoint URL must reference the target, not the source).
- Optionally overrides `enabled` (e.g. `--enabled false` to restore in disabled
  state for safety before verifying).
- Supports `--repo` to restore a single repo from its backup file.
- Supports `--dry-run` (shows what would be PUT, no API call made).

### CLI shape
```bash
python3 push_replication_configure.py restore \
  --source-url https://jpd2.jfrog.io \
  --target-url https://jpd2.jfrog.io \
  --access-token $JPD2_TOKEN \
  --backup-dir replication_backup/ \
  [--repo my-repo-local] \
  [--enabled false] \
  [--dry-run]
```

### DRY / code-reuse notes
- Reuse `get_headers(config)` and `_resolve_path()`.
- Reuse the existing `create_replication_config()` structure but accept a raw
  payload dict (from the backup JSON) instead of building one from config params.
  Extract a shared helper `_put_replication(repo_key, payload, config)` that both
  `create` and `restore` call — avoids duplicating the PUT logic.

---

## Task 3 — Refactor `get-status` to reuse `_fetch_replication_config`

### What it does
Replace the inline GET call in `get_replication_status()` with a call to the
new `_fetch_replication_config()` helper added in Task 1, so all GET-replication
logic lives in one place.

---

## Task 4 — Add `disable` / `enable` single-repo shorthands

### What it does
Add two convenience aliases so operators don't need to remember to pass
`--enabled false` to `update`:

```bash
python3 push_replication_configure.py disable \
  --source-url https://jpd1.jfrog.io \
  --access-token $TOKEN \
  --repo my-repo-local

python3 push_replication_configure.py enable \
  --source-url https://jpd1.jfrog.io \
  --access-token $TOKEN \
  --repo my-repo-local
```

### DRY / code-reuse notes
- Both commands call `update_replication_config()` internally with `enabled`
  forced to `False`/`True` respectively — no new API logic needed.

---

## Task 5 — Merge with colleague's CSV mapping support (discuss with colleague)

While rebasing `preRelease/sureshv` onto the updated `master` (which included
the colleague's commit `c148de9` — "Improve Push Replication: add CSV mapping support"),
conflicts arose in both `push_replication_configure.py` and
`push_replication_configure.md`. Below is a summary of every conflict and how it
was resolved, for review/discussion.

### Conflicts resolved — what was merged from each side

| Area | Colleague's change (CSV support) | My change (backup/restore/disable/enable) | Resolution |
|---|---|---|---|
| `--repo-list` / `--repo` arg descriptions | Updated to mention CSV mode | Unchanged | **Colleague's** updated descriptions kept |
| New CSV args (`--csv`, `--diff-target-repo`, `--col-source/target/project`) | Added | Not present | **Kept** — all CSV args added |
| `--backup-dir` arg | Not present | Added | **Kept** — backup-dir arg added |
| Parameters table in `.md` | CSV rows added; `--repo-list`/`--repo` descriptions updated | `--backup-dir` row added | **Both kept** — all rows present |
| `get_headers(config)` | Defined inline before `get_replication_payload` (duplicate) | Defined once in shared-helpers section | **Deduplicated** — kept the single definition from my section |
| `get_replication_payload` signature | Changed to `(pair, cron_exp, config)` using `RepoPair` | Still `(repo_key, cron_exp, config)` | **Colleague's** pair-based version kept (supports both CSV pairs and plain strings via `_pair_keys`) |
| `_pair_keys(pair)` / `_format_pair(pair)` helpers | New | Not present | **Kept** — required for CSV pair display |
| `create_replication_config` body | Inline `requests.put` with pair/label | Used `_put_replication` shorthand with `repo_key` | **Colleague's** pair-based inline version kept (consistent with rest of pair refactor) |
| `get_replication_status` body | Full pair-based inline GET | Used `_fetch_replication_config` shorthand | **Merged** — pair-based labels kept; body switched to call `_fetch_replication_config` (DRY) |
| `_resolve_pairs(config, single_repo)` | New CSV-aware repo resolver | Not present | **Kept** — used by create/update/get-status/immediate-execution/delete/disable/enable |
| `backup_replication`, `restore_replication_config`, `disable_replication`, `enable_replication` | Not present | New functions | **Kept** — all four new functions added |
| `process_repos` routing | Used `_resolve_pairs` for all commands | Routed backup/restore to special discovery logic | **Merged** — backup uses auto-discovery, restore uses backup-dir listing, all other commands go through `_resolve_pairs` (CSV-aware) |

### Points to discuss with colleague

- `get_replication_status` now calls `_fetch_replication_config` internally instead of
  an inline GET — same behaviour, but DRYer. Confirm this is acceptable.
- `create_replication_config` still uses an inline `requests.put` rather than the
  shared `_put_replication` helper. Consider switching for consistency (low risk).
- The `disable` / `enable` commands bypass `_resolve_pairs` (they always operate on a
  single `--repo`). This is intentional and enforced in `parse_arguments`. Confirm.
- CSV mode (`--csv` / `--diff-target-repo`) is not yet wired into `backup`, `restore`,
  `disable`, or `enable` — those commands only accept `--repo` or auto-discovery.
  Is that the right scope, or should CSV be supported for batch disable/enable?

---

## Complete one-at-a-time migration workflow (target state)

```bash
# 1. Back up all replications from jpd1
python3 push_replication_configure.py backup \
  --source-url https://jpd1.jfrog.io \
  --access-token $JPD1_TOKEN \
  --backup-dir replication_backup/

# 2. For each repo — repeat until all are done:
REPO=my-repo-local

# a) Disable on jpd1
python3 push_replication_configure.py disable \
  --source-url https://jpd1.jfrog.io \
  --access-token $JPD1_TOKEN \
  --repo $REPO

# b) Restore exact config on jpd2 (disabled first for safety)
python3 push_replication_configure.py restore \
  --source-url https://jpd2.jfrog.io \
  --target-url https://jpd2.jfrog.io \
  --access-token $JPD2_TOKEN \
  --backup-dir replication_backup/ \
  --repo $REPO --enabled false

# c) Trigger an immediate run on jpd2 and verify
python3 push_replication_configure.py immediate-execution \
  --source-url https://jpd2.jfrog.io \
  --access-token $JPD2_TOKEN \
  --repo $REPO

# d) Check status
python3 push_replication_configure.py get-status \
  --source-url https://jpd2.jfrog.io \
  --access-token $JPD2_TOKEN \
  --repo $REPO

# e) Once verified — enable on jpd2
python3 push_replication_configure.py enable \
  --source-url https://jpd2.jfrog.io \
  --access-token $JPD2_TOKEN \
  --repo $REPO
```
