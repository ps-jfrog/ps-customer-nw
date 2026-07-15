# Step-by-Step Test Guide: push_replication_configure.py

This guide walks through testing **all five commands** of `push_replication_configure.py` in a safe order: read-only first, then create, update, immediate-execution, and delete (with dry-run where useful).

## Prerequisites

- Python 3.6+ with `requests`: `pip install requests`
- You can run the script from **any folder**. Paths for `--config` and `repo_list_file` are relative to the **current working directory** (or absolute). See [push_replication_configure.md](push_replication_configure.md#paths-and-working-directory).
- Source Artifactory URL and an **access token** with admin permissions
- For **create** and **update**: target Artifactory URL and (optionally) replication username/password
- At least one **local repository** on the source JPD that you can use for testing (e.g. a test repo you create)

## Setup Before Testing

### 1. Optional: Create a config file

Create `config.json` in the same directory (or adjust paths in the commands below):

```json
{
  "source_url": "https://YOUR_SOURCE.jfrog.io",
  "target_url": "https://YOUR_TARGET.jfrog.io",
  "access_token": "YOUR_ACCESS_TOKEN",
  "repo_list_file": "local_repos.txt",
  "replication_username": "",
  "replication_password": "",
  "start_hour": 21,
  "start_minute": 40,
  "interval_minutes": 5
}
```

Replace `YOUR_SOURCE`, `YOUR_TARGET`, and `YOUR_ACCESS_TOKEN` with your values.

### 2. Optional: Create a repo list file

For batch tests, create `local_repos.txt` with one repository key per line (e.g. a single test repo):

```text
my-test-repo-local
```

For the steps below you can use either `--config config.json` or `--source-url` and `--access-token` (and `--target-url` for create/update). Examples show both where helpful.

---

## Step 1: Test `get-status` (read-only)

**Purpose:** Verify connectivity and that the script runs. No replication config is required on the repo.

**Single repo (CLI only; no config file):**

```bash
cd /path/to/push_replication_scripts

python3 push_replication_configure.py get-status \
  --source-url https://YOUR_SOURCE.jfrog.io \
  --access-token YOUR_ACCESS_TOKEN \
  --repo my-test-repo-local
```

**With config file:**

```bash
python3 push_replication_configure.py get-status --config config.json --repo my-test-repo-local
```

**Expected:**

- If the repo has **no** replication: you may get a 404 or an empty/error response (depends on API).
- If the repo **has** replication: JSON with `enabled`, `cronExp`, `url`, etc. is printed.

**Success:** Script runs without Python/argparse errors and returns an API response (even 404).

---

## Step 2: Test `create` with `--dry-run`

**Purpose:** Ensure create would run without making changes.

**Single repo:**

```bash
python3 push_replication_configure.py create \
  --source-url https://YOUR_SOURCE.jfrog.io \
  --target-url https://YOUR_TARGET.jfrog.io \
  --access-token YOUR_ACCESS_TOKEN \
  --repo my-test-repo-local \
  --dry-run
```

**With config file:**

```bash
python3 push_replication_configure.py create --config config.json --repo my-test-repo-local --dry-run
```

**Expected:** Output shows something like `[Dry Run] Would create replication for my-test-repo-local with CRON: ...` and no API call is made.

**Success:** No errors; dry-run message printed.

---

## Step 3: Test `create` (actual)

**Purpose:** Create a replication configuration for one repo.

**Single repo:**

```bash
python3 push_replication_configure.py create \
  --source-url https://YOUR_SOURCE.jfrog.io \
  --target-url https://YOUR_TARGET.jfrog.io \
  --access-token YOUR_ACCESS_TOKEN \
  --repo my-test-repo-local
```

**With config file:**

```bash
python3 push_replication_configure.py create --config config.json --repo my-test-repo-local
```

**Expected:** Message like `Replication configuration created successfully for repo: my-test-repo-local`.

**Success:** Exit code 0 and success message.

---

## Step 4: Test `get-status` again (verify create)

**Purpose:** Confirm the replication config exists after create.

```bash
python3 push_replication_configure.py get-status --config config.json --repo my-test-repo-local
```

Or with CLI only:

```bash
python3 push_replication_configure.py get-status \
  --source-url https://YOUR_SOURCE.jfrog.io \
  --access-token YOUR_ACCESS_TOKEN \
  --repo my-test-repo-local
```

**Expected:** JSON output with `enabled`, `cronExp`, `url` (target), etc.

**Success:** Config is present and matches what you created.

---

## Step 5: Test `update` with `--dry-run`

**Purpose:** Ensure update would run without making changes.

```bash
python3 push_replication_configure.py update --config config.json --repo my-test-repo-local --dry-run
```

Or CLI only (include target URL for consistency):

```bash
python3 push_replication_configure.py update \
  --source-url https://YOUR_SOURCE.jfrog.io \
  --target-url https://YOUR_TARGET.jfrog.io \
  --access-token YOUR_ACCESS_TOKEN \
  --repo my-test-repo-local \
  --dry-run
```

**Expected:** `[Dry Run] Would update replication for my-test-repo-local with CRON: ...`

**Success:** No errors; dry-run message printed.

---

## Step 6: Test `update` (actual)

**Purpose:** Change replication settings (e.g. schedule or options).

Example: change start time via CLI override:

```bash
python3 push_replication_configure.py update \
  --config config.json \
  --repo my-test-repo-local \
  --start-hour 22 \
  --start-minute 0
```

**Expected:** `Replication configuration updated successfully for repo: my-test-repo-local`.

**Success:** Exit code 0 and success message.

---

## Step 7: Test `get-status` again (verify update)

**Purpose:** Confirm the updated config (e.g. new cron).

```bash
python3 push_replication_configure.py get-status --config config.json --repo my-test-repo-local
```

**Expected:** JSON shows updated values (e.g. new `cronExp`).

**Success:** Config reflects the update.

---

## Step 8: Test `immediate-execution` (optional)

**Purpose:** Trigger an immediate push replication run.

**Dry-run first (no execution):**

```bash
python3 push_replication_configure.py immediate-execution --config config.json --repo my-test-repo-local --dry-run
```

**Actual run:**

```bash
python3 push_replication_configure.py immediate-execution --config config.json --repo my-test-repo-local
```

**Expected:** Message like `Immediate replication executed successfully for repo: my-test-repo-local` (or API-specific output).

**Success:** No script/API errors. Replication may take time on the server.

---

## Step 9: Test `delete` with `--dry-run`

**Purpose:** Ensure delete would run without removing config.

```bash
python3 push_replication_configure.py delete --config config.json --repo my-test-repo-local --dry-run
```

**Expected:** `[Dry Run] Would delete replication for my-test-repo-local`

**Success:** No errors; no config removed.

---

## Step 10: Test `delete` (actual)

**Purpose:** Remove the replication configuration.

```bash
python3 push_replication_configure.py delete --config config.json --repo my-test-repo-local
```

Or CLI only:

```bash
python3 push_replication_configure.py delete \
  --source-url https://YOUR_SOURCE.jfrog.io \
  --access-token YOUR_ACCESS_TOKEN \
  --repo my-test-repo-local
```

**Expected:** `Replication configuration deleted successfully for repo: my-test-repo-local`.

**Success:** Exit code 0 and success message.

---

## Step 11: Test `get-status` after delete (optional)

**Purpose:** Confirm replication config is gone.

```bash
python3 push_replication_configure.py get-status --config config.json --repo my-test-repo-local
```

**Expected:** 404 or empty/error from API (no replication config).

**Success:** Script runs; API indicates no config.

---

## Batch Testing (multiple repos)

If you have `local_repos.txt` with multiple repo keys:

1. **get-status** (batch):  
   `python3 push_replication_configure.py get-status --config config.json`
2. **create** with **--dry-run** (batch):  
   `python3 push_replication_configure.py create --config config.json --dry-run`
3. **create** (batch):  
   `python3 push_replication_configure.py create --config config.json`
4. **update** with **--dry-run** then **update** (batch):  
   Same as above with `update` instead of `create`.
5. **immediate-execution** (batch):  
   `python3 push_replication_configure.py immediate-execution --config config.json`
6. **delete** with **--dry-run** then **delete** (batch):  
   `python3 push_replication_configure.py delete --config config.json --dry-run` then without `--dry-run`.

Use a test repo list to avoid affecting production repos.

---

## Quick Reference: All Commands

| Step | Command              | Minimal args (CLI) |
|------|----------------------|--------------------|
| 1    | get-status           | --source-url, --access-token, --repo |
| 2    | create --dry-run     | --source-url, --target-url, --access-token, --repo |
| 3    | create               | same as above |
| 4    | get-status           | same as Step 1 |
| 5    | update --dry-run     | --source-url, --target-url, --access-token, --repo |
| 6    | update               | same as Step 5 (add any overrides) |
| 7    | get-status           | same as Step 1 |
| 8    | immediate-execution  | --source-url, --access-token, --repo (optional --dry-run) |
| 9    | delete --dry-run     | --source-url, --access-token, --repo |
| 10   | delete               | same as Step 9 |
| 11   | get-status           | same as Step 1 (verify 404/empty) |

For full options and config file format, see [push_replication_configure.md](push_replication_configure.md).
