# JFrog Artifactory Push Replication Manager

A Python script to manage push replication configurations for JFrog Artifactory repositories. All settings are provided via a JSON configuration file and/or command-line arguments—**no module-level constants to edit**.

This tool provides create, update, get-status, immediate-execution, delete, backup, restore, disable, and enable operations, with optional batch processing from a repository list or single-repo mode.

> **Migrating replications from one JPD to another?**
> See the step-by-step guide: [QUICKSTART_REPLICATION_MIGRATION.md](QUICKSTART_REPLICATION_MIGRATION.md)

## Features

- **Backup** all push replication configs from a JPD (auto-discovers repos; saves exact JSON per repo)
- **Restore** backed-up configs to a target JPD (rewrites target URL; optional enabled override)
- **Disable** / **Enable** replication for a single repo (`--repo`) or in batch (`--repo-list`) — preserves all other settings (cron, sync flags, etc.)
- **Create** replication configurations (PUT API)
- **Update** existing replication configurations (POST API)
- **Get Status** of replication configurations
- **Execute Immediately** trigger push replication on demand
- **Delete** replication configurations
- **JSON config file** (`--config` / `-c`) with CLI overrides; flexible keys (UPPER or lower case)
- **Configurable target URL** (required for create/update)
- **Proxy support** (`--proxy-name` / `PROXY_NAME`)
- Batch processing from a repository list file, **CSV mapping with different source/target names** (`--csv`), or **single repository** (`--repo`)
- **Dry-run** mode for testing
- Automatic cron scheduling with configurable start time and interval
- Mandatory field validation (source-url, access-token; target-url for create/update)
- **Run from any folder**: `--config` and `repo_list_file` are resolved relative to the **current working directory** or as absolute paths (never relative to the script location)

## Prerequisites

- Python 3.6 or higher
- `requests` library
- Access to JFrog Artifactory instance
- Valid access token with admin permissions

## Installation

```bash
pip install requests
```

## Input: Repository List File

The script can read repository names from a text file (one key per line). Default filename: `local_repos.txt` (overridable via `--repo-list` or config).

Example `local_repos.txt`:

```
acoustic-cicd-npm-local
cui-shell-npm-local
decibel-dev-npm-local
dt-ais-docker-local
```

For single-repo operations, use `--repo <repository_name>` and the list file is not required.

## Paths and working directory

You can run the script from **any folder**. Paths are resolved as follows:

- **`--config`** (and the path inside it): Relative paths are resolved relative to the **current working directory** (the directory from which you run the script). Absolute paths are used as-is. Paths are **not** relative to the script’s location.
- **`repo_list_file`** (in config) or **`--repo-list`**: Same rule—relative paths are relative to the current working directory; absolute paths are used as-is.

Examples: from `/home/me`, `--config ./config.json` means `/home/me/config.json`; `--config /tmp/config.json` is used as-is. So put your config and repo list where you want, then `cd` to that directory and use `./config.json` and `./local_repos.txt`, or use absolute paths.

## Configuration

Configuration can be provided in three ways:

1. **Command-line arguments** (good for one-off runs)
2. **JSON configuration file** (good for repeated use; no editing the script)
3. **Mix of both** (config file with CLI overrides)

Precedence: **CLI arguments > config file > defaults**.

### Option 1: Command-Line Arguments

All parameters can be passed on the command line. Required for **create/update**: `--source-url`, `--target-url`, `--access-token`. Required for **get-status / immediate-execution / delete**: `--source-url`, `--access-token`.

```bash
python3 push_replication_configure.py create \
  --source-url https://source.jfrog.io \
  --target-url https://target.jfrog.io \
  --access-token YOUR_ACCESS_TOKEN \
  --repo-list local_repos.txt \
  --replication-username rep_user \
  --replication-password rep_pass \
  --start-hour 21 \
  --start-minute 40 \
  --interval-minutes 5 \
  --sync-deletes false \
  --sync-properties true \
  --sync-statistics true \
  --proxy-name my-proxy \
  --dry-run
```

### Option 2: JSON Configuration File

Create a JSON file (e.g. `config.json`). Keys can be UPPER or lower case (e.g. `source_url` or `SOURCE_JPD_URL`).

```json
{
  "source_url": "https://source.jfrog.io",
  "target_url": "https://target.jfrog.io",
  "access_token": "your_access_token_here",
  "replication_username": "replication_user",
  "replication_password": "replication_password",
  "repo_list_file": "local_repos.txt",
  "enable_status": true,
  "sync_deletes": false,
  "sync_properties": true,
  "sync_statistics": true,
  "enable_event_replication": true,
  "socket_timeout": 15000,
  "proxy_name": "",
  "start_hour": 21,
  "start_minute": 40,
  "interval_minutes": 5,
  "dry_run": false
}
```

Run with:

```bash
python3 push_replication_configure.py create --config config.json
python3 push_replication_configure.py update --config config.json
python3 push_replication_configure.py get-status --config config.json
```

### Option 3: Config File + CLI Overrides

Use a config file for most settings and override specific values:

```bash
python3 push_replication_configure.py create --config config.json --dry-run
python3 push_replication_configure.py update --config config.json --repo my-repo
```

### Available Parameters

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `--config`, `-c` | No | Path to JSON configuration file | — |
| `--source-url` | Yes | Source JPD URL (e.g. https://source.jfrog.io) | — |
| `--target-url` | Yes (create/update) | Target JPD URL (e.g. https://target.jfrog.io) | — |
| `--access-token` | Yes | Artifactory access token | — |
| `--repo-list` | No | File containing repository list (ignored when `--csv` is set) | `local_repos.txt` |
| `--repo` | No | Single repository key. With `--csv`, looked up against the source-repo column. | — |
| `--csv` | No | CSV mapping `source_repo,target_repo,project` for differently named source/target repos | — |
| `--diff-target-repo` | No | Shortcut to enable CSV mode. Uses `--csv` if given, else `csv_path` from config, else defaults to `repos.csv` in the current directory. | off |
| `--col-source` | No | CSV column for the source repo key | `source_repo` |
| `--col-target` | No | CSV column for the target repo key | `target_repo` |
| `--col-project` | No | CSV column for the project key | `project` |
| `--backup-dir` | No | Directory for backup/restore files | `replication_backup/` |
| `--replication-username` | No | Username for replication authentication | `""` |
| `--replication-password` | No | Password for replication authentication | `""` |
| `--enabled` | No | Enable replication (true/false) | true |
| `--sync-deletes` | No | Sync deletes (true/false) | false |
| `--sync-properties` | No | Sync properties (true/false) | true |
| `--sync-statistics` | No | Sync statistics (true/false) | false |
| `--enable-event-replication` | No | Enable event replication (true/false) | true |
| `--socket-timeout` | No | Socket timeout in milliseconds | 15000 |
| `--proxy-name` | No | Proxy name if used | `""` |
| `--start-hour` | No | Starting hour 0–23 | 21 |
| `--start-minute` | No | Starting minute 0–59 | 40 |
| `--interval-minutes` | No | Minutes between replications (stagger) | 5 |
| `--dry-run` | No | Dry run (no API changes) | false |

**Config file keys** (either casing): `source_url`/`SOURCE_JPD_URL`, `target_url`/`TARGET_JPD_URL`, `access_token`/`ACCESS_TOKEN`, `repo_list_file`/`REPO_LIST_FILE`, `replication_username`/`REPLICATION_USERNAME`, `replication_password`/`REPLICATION_PASSWORD`, `enable_status`/`ENABLE_STATUS`, `sync_deletes`/`SYNC_DELETES`, `sync_properties`/`SYNC_PROPERTIES`, `sync_statistics`/`SYNC_STATISTICS`, `enable_event_replication`/`ENABLE_EVENT_REPLICATION`, `socket_timeout`/`SOCKET_TIMEOUT`, `proxy_name`/`PROXY_NAME`, `start_hour`/`START_HOUR`, `start_minute`/`START_MINUTE`, `interval_minutes`/`INTERVAL_MINUTES`, `dry_run`/`DRY_RUN`.

### What each command needs

- **backup**  
  Needs **source URL** and **access token** only. Optionally `--backup-dir` (default: `replication_backup/`) and `--repo` for a single repo. Auto-discovers all repos with push replication — no repo list file required.

- **restore**  
  Needs **source URL** (the JPD to restore *to*), **target URL** (used to rewrite the replication endpoint URL inside the payload), and **access token**. Optionally `--backup-dir`, `--repo`, and `--enabled true/false` to override the enabled state from the backup.

- **disable, enable**  
  Need **source URL**, **access token**, and either **`--repo`** (single repo) or **`--repo-list`** (batch). They fetch each repo's current config then re-PUT with only `enabled` changed — all other settings (cron, sync flags, etc.) are preserved.

  > **When migrating JPDs, always use `enable`/`disable` rather than `update --enabled`.** The `update` command rebuilds the entire payload from CLI/config defaults and would overwrite the cron expression and sync settings that `restore` preserved from the backup.

- **get-status, immediate-execution, delete**  
  Need only **source URL** and **access token** (via CLI or config). They do *not* need target URL, replication credentials, cron, or proxy. A **repo list file** is only needed for batch runs (when you omit `--repo`); for a single repo use `--repo <key>`. The `--config` file is optional—you can pass `--source-url` and `--access-token` on the command line.

- **create, update**  
  Need **source URL**, **target URL**, and **access token**. The rest (replication username/password, sync options, proxy, schedule, repo list) are optional and use defaults if omitted. Use a config file or CLI for any of these when you’re not relying on defaults.

## Usage

### Basic Commands

```bash
# Back up all push replication configs from a JPD (auto-discovers repos)
python3 push_replication_configure.py backup \
  --source-url https://jpd1.jfrog.io --access-token TOKEN

# Back up with explicit backup directory
python3 push_replication_configure.py backup \
  --source-url https://jpd1.jfrog.io --access-token TOKEN \
  --backup-dir replication_backup/

# Restore all backed-up configs to a target JPD (disabled for safety)
python3 push_replication_configure.py restore \
  --source-url https://jpd2.jfrog.io --target-url https://jpd2.jfrog.io \
  --access-token TOKEN --backup-dir replication_backup/ --enabled false

# Restore a single repo
python3 push_replication_configure.py restore \
  --source-url https://jpd2.jfrog.io --target-url https://jpd2.jfrog.io \
  --access-token TOKEN --backup-dir replication_backup/ --repo my-repo

# Disable replication for a single repo
python3 push_replication_configure.py disable \
  --source-url https://jpd1.jfrog.io --access-token TOKEN --repo my-repo

# Disable replication for all repos in a list (batch)
python3 push_replication_configure.py disable \
  --source-url https://jpd1.jfrog.io --access-token TOKEN --repo-list local_repos.txt

# Enable replication for a single repo
python3 push_replication_configure.py enable \
  --source-url https://jpd2.jfrog.io --access-token TOKEN --repo my-repo

# Enable replication for all repos in a list (batch)
python3 push_replication_configure.py enable \
  --source-url https://jpd2.jfrog.io --access-token TOKEN --repo-list migrated_repos.txt

# Create replication configurations (requires source-url, target-url, access-token via --config or CLI)
python3 push_replication_configure.py create --config config.json

# Update replication configurations
python3 push_replication_configure.py update --config config.json

# Get status (needs only source-url + access-token; --config is optional)
python3 push_replication_configure.py get-status --config config.json
# or CLI only:
python3 push_replication_configure.py get-status --source-url https://source.jfrog.io --access-token TOKEN

# Execute immediate replication (needs only source-url + access-token; --config optional)
python3 push_replication_configure.py immediate-execution --config config.json
# or CLI only:
python3 push_replication_configure.py immediate-execution --source-url https://source.jfrog.io --access-token TOKEN

# Delete replication configurations (needs only source-url + access-token; --config optional)
python3 push_replication_configure.py delete --config config.json
```

### Using CLI Only (No Config File)

**create / update** — need source URL, target URL, and access token; add repo list (or `--repo`) and other options as needed:

```bash
python3 push_replication_configure.py create \
  --source-url https://source.jfrog.io \
  --target-url https://target.jfrog.io \
  --access-token YOUR_TOKEN \
  --repo-list local_repos.txt
```

**get-status / immediate-execution / delete** — need only source URL and access token. Use `--repo` for one repo, or `--repo-list` for batch:

```bash
python3 push_replication_configure.py get-status --source-url https://source.jfrog.io --access-token YOUR_TOKEN

python3 push_replication_configure.py get-status --source-url https://source.jfrog.io --access-token YOUR_TOKEN --repo my-repo

python3 push_replication_configure.py immediate-execution --source-url https://source.jfrog.io --access-token YOUR_TOKEN --repo-list local_repos.txt

python3 push_replication_configure.py delete --source-url https://source.jfrog.io --access-token YOUR_TOKEN --repo my-repo
```

### Single Repository Operations

For **get-status**, **immediate-execution**, and **delete** you can use only `--source-url`, `--access-token`, and `--repo` (no config file). For **create** and **update** you still need target URL (and optionally config for other options).

```bash
# Get status for a specific repository (config optional)
python3 push_replication_configure.py get-status --source-url https://source.jfrog.io --access-token TOKEN --repo acoustic-cicd-npm-local

# Create replication for a specific repository (needs target URL)
python3 push_replication_configure.py create --config config.json --repo acoustic-cicd-npm-local

# Update replication for a specific repository
python3 push_replication_configure.py update --config config.json --repo acoustic-cicd-npm-local

# Execute immediate replication for a specific repository (config optional)
python3 push_replication_configure.py immediate-execution --source-url https://source.jfrog.io --access-token TOKEN --repo acoustic-cicd-npm-local

# Delete replication for a specific repository (config optional)
python3 push_replication_configure.py delete --source-url https://source.jfrog.io --access-token TOKEN --repo acoustic-cicd-npm-local
```

### Dry Run Mode

Test without making API calls:

```bash
python3 push_replication_configure.py create --config config.json --dry-run
python3 push_replication_configure.py update --config config.json --dry-run
python3 push_replication_configure.py delete --config config.json --dry-run
```

## Command Reference

| Command | Description | API |
|---------|-------------|-----|
| `backup` | Auto-discover all repos with push replication and save each config as `<backup-dir>/<repo>.json` | GET `/artifactory/api/replications` |
| `restore` | Read backed-up JSON and PUT it verbatim to the target JPD (rewrites target URL; optional `--enabled` override) | PUT `/artifactory/api/replications/{repoKey}` |
| `disable` | Disable replication for one repo (`--repo`) or batch (`--repo-list`); preserves all other settings | GET + PUT `/artifactory/api/replications/{repoKey}` |
| `enable` | Enable replication for one repo (`--repo`) or batch (`--repo-list`); preserves all other settings | GET + PUT `/artifactory/api/replications/{repoKey}` |
| `create` | Create a new replication configuration | [Set Repository Replication Configuration](https://jfrog.com/help/r/jfrog-rest-apis/set-repository-replication-configuration) (PUT) |
| `update` | Update an existing replication configuration | [Update Repository Replication Configuration](https://jfrog.com/help/r/jfrog-rest-apis/update-repository-replication-configuration) (POST) |
| `get-status` | Get the status of a replication configuration | [Scheduled Replication Status](https://jfrog.com/help/r/jfrog-rest-apis/scheduled-replication-status) (GET) |
| `immediate-execution` | Trigger immediate push replication | [Push Replication](https://jfrog.com/help/r/jfrog-rest-apis/pull/push-replication) (POST execute) |
| `delete` | Delete a replication configuration | [Delete Repository Replication Configuration](https://jfrog.com/help/r/jfrog-rest-apis/delete-repository-replication-configuration) (DELETE) |

## Cron Expression Format

Generated cron format: `0 {minute} {hour} * * ?`

- Minutes: 0–59, Hours: 0–23 (24-hour)
- For batch create/update, each repo is staggered by `interval_minutes`

Example: `0 40 21 * * ?` = run at 21:40 every day.

## Examples

### Example 1: Create Replication Using Config File

```bash
python3 push_replication_configure.py create --config config.json
```

Output (conceptually):

```text
Configuration:
  Source JPD: https://source.jfrog.io
  Target JPD: https://target.jfrog.io
  Start time: 21:40
  Interval: 5 minutes
  Dry run: False
  Repositories: 3

Creating replication for example-repo-1 with CRON: 0 40 21 * * ?
✓ Replication configuration created successfully for repo: example-repo-1
...
Operation completed: 3/3 repositories processed successfully.
```

### Example 2: Dry Run (Config + Override)

```bash
python3 push_replication_configure.py update --config config.json --dry-run
```

```text
Running in DRY RUN mode - no changes will be made

Configuration:
  Source JPD: https://source.jfrog.io
  Target JPD: https://target.jfrog.io
  Start time: 21:40
  Interval: 5 minutes
  Dry run: True
  Repositories: 3

[Dry Run] Would update replication for example-repo-1 with CRON: 0 40 21 * * ?
[Dry Run] Would update replication for example-repo-2 with CRON: 0 45 21 * * ?
...

Dry run completed!
```

### Example 3: Get Status for One Repository (CLI only; no config)

```bash
python3 push_replication_configure.py get-status --source-url https://source.jfrog.io --access-token TOKEN --repo dt-npm-local
```

### Example 4: Execute Immediate Replication (CLI only; no config)

```bash
python3 push_replication_configure.py immediate-execution --source-url https://source.jfrog.io --access-token TOKEN --repo dt-docker-local
```

### Example 5: CLI Only (No Config File)

```bash
python3 push_replication_configure.py create \
  --source-url https://source.jfrog.io \
  --target-url https://target.jfrog.io \
  --access-token "$ARTIFACTORY_TOKEN" \
  --repo-list repos.txt \
  --start-hour 21 \
  --start-minute 40 \
  --interval-minutes 5
```

## Error Handling

- **HTTP errors**: Status code and response body are printed.
- **Validation**: Missing `--source-url`, `--access-token`, or `--target-url` (for create/update) produces a clear error.
- **File not found**: If the repository list file is missing, the script reports it and exits.

Example:

```text
✗ Failed to create replication for repo invalid-repo: 404 Client Error: Not Found
  Response status: 404
  Response body: {"errors":[{"status":404,"message":"Repository not found"}]}
```

## Troubleshooting

1. **"source-url is required" / "access-token is required"**  
   All commands need these (via config or CLI). For get-status, immediate-execution, and delete that is all you need; no target URL or config file required.

2. **"target-url is required for create/update"**  
   Add `target_url` to your config or use `--target-url` when running create/update.

3. **"File ... not found"**  
   Create the repository list file or set `--repo-list` to the correct path (or use `--repo` for a single repo).

4. **401 Unauthorized**  
   Check that `access_token` is valid and has admin permissions.

5. **404 Not Found**  
   Verify the repository key and that `source_url` is correct.

6. **Connection timeout**  
   Check network and Artifactory URL; increase `socket_timeout` if needed.

## Security Notes

- Do not commit config files or scripts containing real tokens or passwords.
- Prefer environment variables for tokens, e.g. `--access-token "$ARTIFACTORY_TOKEN"`.
- Use `--dry-run` to validate before applying changes.
- Use HTTPS for all Artifactory URLs.

## API Endpoints Used

- **GET** `/artifactory/api/replications` — List all replication entries (used by `backup` auto-discovery)
- **GET** `/artifactory/api/replications/{repoKey}` — Fetch a repo's replication config (used by `get-status`, `backup`, `disable`, `enable`)
- **PUT** `/artifactory/api/replications/{repoKey}` — Create or restore a replication config (used by `create`, `restore`, `disable`, `enable`)
- **POST** `/artifactory/api/replications/{repoKey}` — Update an existing replication config (used by `update`)
- **POST** `/artifactory/api/replication/execute/{repoPath}` — Trigger immediate push replication ([Push Replication](https://jfrog.com/help/r/jfrog-rest-apis/pull/push-replication))
- **DELETE** `/artifactory/api/replications/{repoKey}` — Delete a replication config

[JFrog REST API Documentation](https://jfrog.com/help/r/jfrog-rest-apis/)

---

## Input: CSV with different source / target repo names

Use this when the **source repo name on the source JPD is different from the target repo name on the target JPD** — typical when target repos are project-scoped (e.g. source `local-alpine` → target `eaei-local-alpine`). Both sides must share the same package type.

### 1. CSV file (`repos.csv`)

Same shape as `create_project_repo.py` and `move_repo_contents.py`:

```csv
source_repo,target_repo,project
docker-local-mims,local-docker,mims
maven-local-giftcard,local-maven,giftcard
nuget-local-dapd,local-nuget,dapd
nuget-local-eaei,local-nuget,eaei
```

The effective target on the target JPD is `<project>-<target_repo>` (e.g. `mims-local-docker`).

### 2. `config.json`

```json
{
  "source_url": "https://source.jfrog.io",
  "target_url": "https://target.jfrog.io",
  "access_token": "YOUR_TOKEN",
  "replication_username": "rep_user",
  "replication_password": "rep_pass",
  "csv_path": "repos.csv",
  "enable_status": true,
  "sync_deletes": false,
  "sync_properties": true,
  "sync_statistics": false,
  "enable_event_replication": true,
  "start_hour": 21,
  "start_minute": 40,
  "interval_minutes": 5
}
```

### 3. Commands (all five operations)

Always start with a dry-run to confirm the source → target pairs:

```bash
python3 push_replication_configure.py create --config config.json --diff-target-repo --dry-run
```

Then pick the operation you need:

```bash
# Create replication on the source JPD for every CSV row
python3 push_replication_configure.py create --config config.json --diff-target-repo

# Update existing replication configs (cron, sync flags, target URL, etc.)
python3 push_replication_configure.py update --config config.json --diff-target-repo

# Show current replication status for every CSV row
python3 push_replication_configure.py get-status --config config.json --diff-target-repo

# Trigger an immediate push for every CSV row
python3 push_replication_configure.py immediate-execution --config config.json --diff-target-repo

# Delete the replication config for every CSV row
python3 push_replication_configure.py delete --config config.json --diff-target-repo
```

Run a single CSV row by adding `--repo <source_repo>` (must match the `source_repo` column):

```bash
python3 push_replication_configure.py create --config config.json --diff-target-repo --repo docker-local-mims
```

### Notes

- `--diff-target-repo` is just a shortcut: it enables CSV mode and defaults the CSV path to `repos.csv` in the current directory if neither `--csv` nor `csv_path` (in config) is set.
- All operations target the **source** repo key on the source JPD (that's where the replication config lives). The target name is only used inside the payload's `url`.
- `create` / `update` apply the staggered cron schedule (`start_hour`, `start_minute`, `interval_minutes`) across CSV rows in order.
- Target repos must already exist on the target JPD with the matching package type — use `create_project_repo.py` first if needed.

---

**Last Updated**: 2025
