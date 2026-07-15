# Quickstart: Migrate Push Replications from jpd1 to jpd2

Use this guide when you want to move push replication configurations from one
Artifactory JPD (**jpd1**, the source) to another (**jpd2**, the target) one
repository at a time, verifying each migration before proceeding to the next.

The workflow per repository is:

1. **Backup** all push replication configs from jpd1 (done once)
2. **Disable** the replication for one repo on jpd1
3. **Restore** the exact same config on jpd2
4. **Trigger** an immediate replication on jpd2 and verify it completes
5. **Enable** the replication on jpd2
6. Repeat steps 2–5 for the next repository

---

## Prerequisites

- Python 3.6+ with the `requests` library (`pip install requests`)
- Access tokens for both jpd1 and jpd2 with **admin** permissions
- `push_replication_configure.py` in your working directory

### Environment variables (recommended — avoids tokens in shell history)

```bash
export JPD1_URL="https://jpd1.jfrog.io"
export JPD1_TOKEN="<admin-token-for-jpd1>"
export JPD2_URL="https://jpd2.jfrog.io"
export JPD2_TOKEN="<admin-token-for-jpd2>"
```

---

## Part 1 — Back up all push replications from jpd1

Run once before starting any migrations. The script auto-discovers every repo
with push replication configured — no pre-populated repo list needed.

```bash
python3 push_replication_configure.py backup \
  --source-url $JPD1_URL \
  --access-token $JPD1_TOKEN \
  --backup-dir replication_backup/
```

**Dry run first** (no files written):

```bash
python3 push_replication_configure.py backup \
  --source-url $JPD1_URL \
  --access-token $JPD1_TOKEN \
  --backup-dir replication_backup/ \
  --dry-run
```

**Expected output:**

```
Configuration:
  Source JPD: https://jpd1.jfrog.io
  Backup dir: /path/to/replication_backup
  Dry run: False

Auto-discovering repos with push replications...
Found 5 repo(s) with push replication configured.
✓ Backed up replication config for my-docker-local → replication_backup/my-docker-local.json
✓ Backed up replication config for my-npm-local   → replication_backup/my-npm-local.json
...
Operation completed: 5/5 repositories processed successfully.
```

Each JSON file contains the **exact** replication configuration for that repo
(cron expression, sync flags, enabled state, etc.) ready for restore.

---

## Part 2 — Migrate one repository at a time

Repeat the following steps for each repository. Replace `my-docker-local` with
the actual repo key.

```bash
REPO=my-docker-local
```

### Step 2.1 — Review the backed-up config

```bash
cat replication_backup/$REPO.json
```

Confirm the config looks correct (target URL, cron schedule, sync settings)
before disabling and restoring.

### Step 2.2 — Disable the replication on jpd1

This preserves all existing config settings — only `enabled` is set to `false`.

```bash
python3 push_replication_configure.py disable \
  --source-url $JPD1_URL \
  --access-token $JPD1_TOKEN \
  --repo $REPO
```

**Expected output:**

```
Disabling replication for my-docker-local...
✓ Replication disabled for repo: my-docker-local
```

Verify it is disabled on jpd1:

```bash
python3 push_replication_configure.py get-status \
  --source-url $JPD1_URL \
  --access-token $JPD1_TOKEN \
  --repo $REPO
```

Look for `"enabled": false` in the output.

### Step 2.3 — Dry-run the restore on jpd2

Always preview the restore before applying it:

```bash
python3 push_replication_configure.py restore \
  --source-url $JPD2_URL \
  --target-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --backup-dir replication_backup/ \
  --repo $REPO \
  --enabled false \
  --dry-run
```

> **Why `--enabled false`?**  Restoring in disabled state is a safety net —
> you can verify the configuration looks correct on jpd2 before the first
> scheduled run fires.

### Step 2.4 — Restore the replication config on jpd2

```bash
python3 push_replication_configure.py restore \
  --source-url $JPD2_URL \
  --target-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --backup-dir replication_backup/ \
  --repo $REPO \
  --enabled false
```

**Expected output:**

```
Restoring replication for my-docker-local from replication_backup/my-docker-local.json...
✓ Replication configuration restored successfully for repo: my-docker-local
```

Confirm the restored config on jpd2:

```bash
python3 push_replication_configure.py get-status \
  --source-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --repo $REPO
```

Check that `url`, `cronExp`, `syncDeletes`, `syncProperties`, etc. are correct,
and that `"enabled": false`.

### Step 2.5 — Enable the replication on jpd2

```bash
python3 push_replication_configure.py enable \
  --source-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --repo $REPO
```

### Step 2.6 — Trigger an immediate replication and verify

```bash
python3 push_replication_configure.py immediate-execution \
  --source-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --repo $REPO
```

**Expected output:**

```
Executing immediate replication for my-docker-local...
✓ Immediate replication executed successfully for repo: my-docker-local
```

After the replication run completes, verify in the Artifactory UI (or via the
status command below) that the artifacts have been replicated correctly:

```bash
python3 push_replication_configure.py get-status \
  --source-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --repo $REPO
```

### Step 2.7 — Proceed to the next repository

Once the replication run on jpd2 is confirmed successful, repeat Steps 2.1–2.6
with the next `REPO` value.

---

## Part 3 — Full batch restore (optional)

If all repositories have been verified and you want to restore the remaining
configs to jpd2 in one go (without `--repo`), the script processes every JSON
file found in `--backup-dir`:

```bash
# Dry run first
python3 push_replication_configure.py restore \
  --source-url $JPD2_URL \
  --target-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --backup-dir replication_backup/ \
  --enabled false \
  --dry-run

# Live run
python3 push_replication_configure.py restore \
  --source-url $JPD2_URL \
  --target-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --backup-dir replication_backup/ \
  --enabled false
```

---

## Part 4 — Re-enable all replications on jpd2

After verifying all repos, enable them all at once using the `enable` command
with `--repo-list`. This fetches and re-PUTs each repo's current config with
only `enabled` changed — **the cron expression and all other settings from the
restore are fully preserved**.

> **Why not `update --enabled true`?**  The `update` command rebuilds the
> entire payload from CLI/config parameters (including the cron schedule),
> which would **overwrite** the original schedule that `restore` carefully
> preserved from the backup. Always use `enable` / `disable` when you only
> want to change the enabled state.

```bash
# List all backed-up repo keys
ls replication_backup/*.json | xargs -I{} basename {} .json > migrated_repos.txt

# Dry run first
python3 push_replication_configure.py enable \
  --source-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --repo-list migrated_repos.txt \
  --dry-run

# Live run
python3 push_replication_configure.py enable \
  --source-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --repo-list migrated_repos.txt
```

---

## Quick Reference

| Step | Command | JPD |
|------|---------|-----|
| Back up all replication configs | `backup` | jpd1 |
| Disable one repo's replication | `disable --repo <key>` | jpd1 |
| Check disabled status | `get-status --repo <key>` | jpd1 |
| Restore config (disabled) | `restore --repo <key> --enabled false` | jpd2 |
| Check restored config | `get-status --repo <key>` | jpd2 |
| Enable on jpd2 | `enable --repo <key>` | jpd2 |
| Trigger immediate run | `immediate-execution --repo <key>` | jpd2 |
| Verify status | `get-status --repo <key>` | jpd2 |

---

## Rollback

If a migration fails and you need to re-enable the replication on jpd1:

```bash
python3 push_replication_configure.py enable \
  --source-url $JPD1_URL \
  --access-token $JPD1_TOKEN \
  --repo $REPO
```

And delete the failed config from jpd2 (if partially created):

```bash
python3 push_replication_configure.py delete \
  --source-url $JPD2_URL \
  --access-token $JPD2_TOKEN \
  --repo $REPO
```

---

## Troubleshooting

| Error | Likely cause | Fix |
|-------|-------------|-----|
| `✗ Failed to fetch replication config` | Repo has no replication or wrong URL | Confirm the repo key and that a replication exists |
| `✗ Backup file not found` | `--backup-dir` path is wrong or backup wasn't run | Re-run `backup` or correct `--backup-dir` |
| `401 Unauthorized` | Token expired or insufficient permissions | Refresh the access token |
| `404 Not Found` | Repo does not exist on target JPD | Create the repo on jpd2 first |
| `No repos with push replication found` | Discovery call returned empty | Confirm push replications exist in jpd1 UI |
