#!/usr/bin/env python3
"""
Manage JFrog Artifactory push replication configurations.
All settings via --config JSON file and/or CLI; no module-level constants to edit.

Path behavior: --config and repo_list_file (in config or --repo-list) are resolved
relative to the current working directory (cwd) or as absolute paths. You can run
the script from any folder; paths are never relative to the script location.
"""
import requests
import json
import argparse
import csv
import os
import sys
from collections import namedtuple
from typing import Optional

def effective_target_repo_key(csv_target_repo: str, project_key: Optional[str]) -> str:
    """
    Project-scoped repos on the Platform must use keys like ``{projectKey}-local-maven``.
    If CSV target already starts with ``{projectKey}-``, it is left unchanged; otherwise the
    prefix is added (project key lowercased).
    """
    t = csv_target_repo.strip()
    pk = (project_key or "").strip().lower()
    if not pk:
        return t
    prefix = f"{pk}-"
    if t.lower().startswith(prefix):
        return t
    return prefix + t

RepoPair = namedtuple("RepoPair", ["source_repo", "target_repo"])


def _resolve_path(path):
    """Resolve path relative to current working directory if not absolute."""
    if not path:
        return path
    if os.path.isabs(path):
        return path
    return os.path.normpath(os.path.join(os.getcwd(), path))


def load_config_file(config_file):
    """Load configuration from JSON file. Accepts UPPER or lower case keys.
    config_file is resolved relative to cwd if not absolute.
    """
    if not config_file:
        return {}
    resolved = _resolve_path(config_file)
    if not os.path.exists(resolved):
        return {}
    try:
        with open(resolved, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        print(f"Error parsing config file {resolved}: {e}")
        return {}


def _bool_from_config(config, *keys, default=True):
    """Get boolean from config with multiple key names (e.g. ENABLE_STATUS, enable_status)."""
    for k in keys:
        if k in config and config[k] is not None:
            v = config[k]
            if isinstance(v, bool):
                return v
            if isinstance(v, str):
                return v.lower() in ('true', '1', 'yes')
    return default


def _int_from_config(config, *keys, default=0):
    """Get int from config with multiple key names."""
    for k in keys:
        if k in config and config[k] is not None:
            try:
                return int(config[k])
            except (TypeError, ValueError):
                pass
    return default


def _str_from_config(config, *keys, default=''):
    """Get string from config with multiple key names."""
    for k in keys:
        if k in config and config[k] is not None:
            return str(config[k]).strip()
    return default


def parse_arguments():
    """Parse command-line arguments and optional config file. Returns (command, single_repo, config dict)."""
    parser = argparse.ArgumentParser(
        description='Manage JFrog Artifactory push replication configurations',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 push_replication_configure.py backup --source-url https://jpd1.jfrog.io --access-token TOKEN
  python3 push_replication_configure.py restore --source-url https://jpd2.jfrog.io --target-url https://jpd2.jfrog.io --access-token TOKEN
  python3 push_replication_configure.py restore --source-url https://jpd2.jfrog.io --target-url https://jpd2.jfrog.io --access-token TOKEN --repo my-repo --enabled false
  python3 push_replication_configure.py disable --source-url https://jpd1.jfrog.io --access-token TOKEN --repo my-repo
  python3 push_replication_configure.py enable  --source-url https://jpd2.jfrog.io --access-token TOKEN --repo my-repo
  python3 push_replication_configure.py create --config config.json
  python3 push_replication_configure.py update --source-url https://source.jfrog.io --target-url https://target.jfrog.io --access-token TOKEN
  python3 push_replication_configure.py get-status --config config.json --repo my-repo
  python3 push_replication_configure.py immediate-execution --config config.json --dry-run
  python3 push_replication_configure.py delete --config config.json

  All options can be set in a JSON config file (--config / -c); CLI overrides config.
  Required for create/update/restore: source-url, target-url, access-token.
  Required for get-status/immediate-execution/delete/backup/disable/enable: source-url, access-token.
        """
    )
    parser.add_argument(
        'command',
        choices=['create', 'update', 'get-status', 'immediate-execution', 'delete',
                 'backup', 'restore', 'disable', 'enable'],
        help='Operation: create, update, get-status, immediate-execution, delete, backup, restore, disable, or enable'
    )
    parser.add_argument('--config', '-c', type=str, help='Path to JSON configuration file')
    parser.add_argument('--source-url', type=str, help='Source JPD URL (e.g., https://source.jfrog.io)')
    parser.add_argument('--target-url', type=str, help='Target JPD URL (e.g., https://target.jfrog.io)')
    parser.add_argument('--access-token', type=str, help='Artifactory access token')
    parser.add_argument('--replication-username', type=str, help='Username for replication authentication')
    parser.add_argument('--replication-password', type=str, help='Password for replication authentication')
    parser.add_argument('--repo-list', type=str, help='File containing repository list (default: local_repos.txt). Ignored when --csv is set.')
    parser.add_argument('--repo', type=str, help='Process a single repository instead of list from file. With --csv, looked up against the source-repo column.')
    parser.add_argument('--csv', dest='csv_path', type=str, help='Path to CSV mapping source_repo,target_repo,project (same shape as create_project_repo.py / move_repo_contents.py). Each row sets up replication from source_repo on the source JPD to the project-scoped effective target repo on the target JPD (default: <project>-<target_repo>). Implies CSV mode.')
    parser.add_argument('--diff-target-repo', dest='diff_target_repo', action='store_true', default=None, help='Shortcut to enable CSV mode for replicating to differently named target repos. Uses --csv if given, else CSV_PATH from --config, else defaults to repos.csv in the current working directory.')
    parser.add_argument('--col-source', type=str, default='source_repo', help='CSV column for the source repo key (default: source_repo).')
    parser.add_argument('--col-target', type=str, default='target_repo', help='CSV column for the target repo key (default: target_repo).')
    parser.add_argument('--col-project', type=str, default='project', help='CSV column for the project key (default: project).')
    parser.add_argument('--dry-run', action='store_true', help='Dry run (no changes made)')
    parser.add_argument('--backup-dir', type=str, help='Directory for backup/restore files (default: replication_backup/)')

    # Replication settings
    parser.add_argument('--enabled', type=lambda x: x.lower() == 'true' if x else None, help='Enable replication (true/false)')
    parser.add_argument('--sync-deletes', type=lambda x: x.lower() == 'true' if x else None, help='Sync deletes (true/false)')
    parser.add_argument('--sync-properties', type=lambda x: x.lower() == 'true' if x else None, help='Sync properties (true/false)')
    parser.add_argument('--sync-statistics', type=lambda x: x.lower() == 'true' if x else None, help='Sync statistics (true/false)')
    parser.add_argument('--enable-event-replication', type=lambda x: x.lower() == 'true' if x else None, help='Enable event replication (true/false)')
    parser.add_argument('--socket-timeout', type=int, help='Socket timeout in milliseconds')
    parser.add_argument('--proxy-name', type=str, help='Proxy name (if any)')

    # Scheduling (for create/update)
    parser.add_argument('--start-hour', type=int, help='Starting hour (0-23, default: 21)')
    parser.add_argument('--start-minute', type=int, help='Starting minute (0-59, default: 40)')
    parser.add_argument('--interval-minutes', type=int, help='Interval between replications in minutes (default: 5)')

    args = parser.parse_args()
    raw_config = load_config_file(_resolve_path(args.config) if args.config else None)

    # Build final config: CLI > config file > defaults (flexible keys: UPPER or lower)
    def get(key_pairs, default=None):
        for cli_val, config_keys in key_pairs:
            if cli_val is not None and cli_val != '':
                return cli_val
            for ck in config_keys:
                if ck in raw_config and raw_config[ck] is not None:
                    return raw_config[ck]
        return default

    source_url = get([
        (args.source_url, ['SOURCE_JPD_URL', 'source_url']),
    ])
    target_url = get([
        (args.target_url, ['TARGET_JPD_URL', 'target_url']),
    ])
    access_token = get([
        (args.access_token, ['ACCESS_TOKEN', 'access_token']),
    ])
    repo_list_file = get([
        (args.repo_list, ['REPO_LIST_FILE', 'repo_list_file']),
    ], 'local_repos.txt')
    replication_username = get([
        (args.replication_username, ['REPLICATION_USERNAME', 'replication_username']),
    ], '')
    replication_password = get([
        (args.replication_password, ['REPLICATION_PASSWORD', 'replication_password']),
    ], '')
    backup_dir = get([
        (args.backup_dir, ['BACKUP_DIR', 'backup_dir']),
    ], 'replication_backup')

    enabled = args.enabled if args.enabled is not None else _bool_from_config(raw_config, 'ENABLE_STATUS', 'enable_status', default=True)
    sync_deletes = args.sync_deletes if args.sync_deletes is not None else _bool_from_config(raw_config, 'SYNC_DELETES', 'sync_deletes', default=False)
    sync_properties = args.sync_properties if args.sync_properties is not None else _bool_from_config(raw_config, 'SYNC_PROPERTIES', 'sync_properties', default=True)
    sync_statistics = args.sync_statistics if args.sync_statistics is not None else _bool_from_config(raw_config, 'SYNC_STATISTICS', 'sync_statistics', default=False)
    enable_event_replication = args.enable_event_replication if args.enable_event_replication is not None else _bool_from_config(raw_config, 'ENABLE_EVENT_REPLICATION', 'enable_event_replication', default=True)
    socket_timeout = args.socket_timeout or _int_from_config(raw_config, 'SOCKET_TIMEOUT', 'socket_timeout', default=15000)
    proxy_name = get([
        (args.proxy_name, ['PROXY_NAME', 'proxy_name']),
    ], '') or ''

    start_hour = args.start_hour if args.start_hour is not None else _int_from_config(raw_config, 'start_hour', 'START_HOUR', default=21)
    start_minute = args.start_minute if args.start_minute is not None else _int_from_config(raw_config, 'start_minute', 'START_MINUTE', default=40)
    interval_minutes = args.interval_minutes or _int_from_config(raw_config, 'interval_minutes', 'INTERVAL_MINUTES', default=5)
    dry_run = args.dry_run or _bool_from_config(raw_config, 'DRY_RUN', 'dry_run', default=False)

    csv_path = get([
        (args.csv_path, ['CSV_PATH', 'csv_path', 'CSV', 'csv']),
    ], '') or ''

    # --diff-target-repo (or diff_target_repo in config) enables CSV mode and falls
    # back to repos.csv (cwd) when no explicit CSV path was given.
    diff_target_repo = args.diff_target_repo if args.diff_target_repo is not None else _bool_from_config(
        raw_config, 'DIFF_TARGET_REPO', 'diff_target_repo', default=False
    )
    if diff_target_repo and not csv_path:
        csv_path = 'repos.csv'

    config = {
        'SOURCE_JPD_URL': source_url,
        'TARGET_JPD_URL': target_url,
        'ACCESS_TOKEN': access_token,
        'REPO_LIST_FILE': repo_list_file,
        'CSV_PATH': csv_path,
        'COL_SOURCE': args.col_source,
        'COL_TARGET': args.col_target,
        'COL_PROJECT': args.col_project,
        'REPLICATION_USERNAME': replication_username,
        'REPLICATION_PASSWORD': replication_password,
        'ENABLE_STATUS': enabled,
        'SYNC_DELETES': sync_deletes,
        'SYNC_PROPERTIES': sync_properties,
        'SYNC_STATISTICS': sync_statistics,
        'ENABLE_EVENT_REPLICATION': enable_event_replication,
        'SOCKET_TIMEOUT': socket_timeout,
        'PROXY_NAME': proxy_name,
        'start_hour': start_hour,
        'start_minute': start_minute,
        'interval_minutes': interval_minutes,
        'DRY_RUN': dry_run,
        'BACKUP_DIR': backup_dir,
    }

    # Validation: source and token required for all commands
    if not config['SOURCE_JPD_URL']:
        parser.error('--source-url is required (or set in config file)')
    if not config['ACCESS_TOKEN']:
        parser.error('--access-token is required (or set in config file)')
    if args.command in ('create', 'update', 'restore') and not config['TARGET_JPD_URL']:
        parser.error('--target-url is required for create/update/restore (or set in config file)')
    if args.command in ('disable', 'enable') and not args.repo and not repo_list_file:
        parser.error('--repo or --repo-list is required for disable/enable')

    return args.command, args.repo, config


# ---------------------------------------------------------------------------
# Shared low-level helpers
# ---------------------------------------------------------------------------

def get_headers(config):
    return {
        "Authorization": f"Bearer {config['ACCESS_TOKEN']}",
        "Content-Type": "application/json"
    }


def _fetch_replication_config(repo_key, config):
    """Fetch the replication configuration for a single repo from the source JPD.

    Returns the parsed JSON (dict or list) on success, or None on error.
    This is the single authoritative GET for a repo's replication config,
    used by get-status, backup, and restore verification.
    """
    url = f"{config['SOURCE_JPD_URL'].rstrip('/')}/artifactory/api/replications/{repo_key}"
    headers = get_headers(config)
    try:
        response = requests.get(url, headers=headers, timeout=10)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"✗ Failed to fetch replication config for {repo_key}: {e}")
        if hasattr(e, 'response') and e.response is not None:
            print(f"  Response status: {e.response.status_code}")
            print(f"  Response body: {e.response.text}")
        return None


def _discover_replicated_repos(config):
    """Return a list of repo keys that have push replications on the source JPD.

    Calls GET /artifactory/api/replications (no repo key) which returns all
    replication entries. Deduplicates by repoKey so each repo appears once.
    Falls back to an empty list on error.
    """
    url = f"{config['SOURCE_JPD_URL'].rstrip('/')}/artifactory/api/replications"
    headers = get_headers(config)
    try:
        response = requests.get(url, headers=headers, timeout=10)
        response.raise_for_status()
        data = response.json()
        # The API returns a list of replication entries; each has a 'repoKey' field.
        seen = set()
        repos = []
        for entry in (data if isinstance(data, list) else [data]):
            rk = entry.get('repoKey') or entry.get('repokey') or entry.get('repo_key')
            if rk and rk not in seen:
                seen.add(rk)
                repos.append(rk)
        return repos
    except requests.exceptions.RequestException as e:
        print(f"✗ Failed to discover replicated repos: {e}")
        if hasattr(e, 'response') and e.response is not None:
            print(f"  Response status: {e.response.status_code}")
            print(f"  Response body: {e.response.text}")
        return []


def _put_replication(repo_key, payload, config):
    """PUT a replication payload to the source JPD for the given repo.

    Used by both create_replication_config() and restore_replication_config()
    so all PUT logic lives in one place.
    Returns True on success, False on failure.
    """
    url = f"{config['SOURCE_JPD_URL'].rstrip('/')}/artifactory/api/replications/{repo_key}"
    headers = get_headers(config)
    try:
        response = requests.put(url, headers=headers, data=json.dumps(payload), timeout=10)
        response.raise_for_status()
        return True
    except requests.exceptions.RequestException as e:
        print(f"✗ Failed to PUT replication for repo {repo_key}: {e}")
        if hasattr(e, 'response') and e.response is not None:
            print(f"  Response status: {e.response.status_code}")
            print(f"  Response body: {e.response.text}")
        return False


# ---------------------------------------------------------------------------
# Existing operations
# ---------------------------------------------------------------------------

def get_repositories_from_file(repo_list_file):
    """Read repository list from file. repo_list_file is resolved relative to cwd if not absolute."""
    if not repo_list_file:
        return []
    resolved = _resolve_path(repo_list_file)
    try:
        with open(resolved, 'r') as f:
            return [line.strip() for line in f if line.strip()]
    except FileNotFoundError:
        print(f"File {resolved} not found. Aborting.")
        return []


def get_repo_pairs_from_csv(csv_file, col_source, col_target, col_project):
    """Read (source_repo, effective_target_repo) pairs from a CSV.

    Mirrors the column conventions of create_project_repo.py: required columns
    `source_repo` and `target_repo`, optional `project`. Effective target repo
    key uses `<project>-<target_repo>` when a project is set (and the target
    does not already start with that prefix).

    Duplicate (source, effective_target) pairs are kept in first-seen order.
    Rows missing source or target are skipped with a warning.
    """
    if not csv_file:
        return []
    resolved = _resolve_path(csv_file)
    try:
        with open(resolved, newline='', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            if not reader.fieldnames:
                print(f"CSV {resolved} has no header row. Aborting.")
                return []
            for required in (col_source, col_target):
                if required not in reader.fieldnames:
                    print(f"CSV {resolved} is missing required column {required!r}. Found columns: {reader.fieldnames}")
                    return []
            seen = set()
            pairs = []
            for i, row in enumerate(reader, start=2):
                src = (row.get(col_source) or '').strip()
                tgt = (row.get(col_target) or '').strip()
                proj = (row.get(col_project) or '').strip().lower() if col_project in (reader.fieldnames or []) else ''
                if not src or not tgt:
                    print(f"  ! Skipping CSV line {i}: empty source or target ({src!r}, {tgt!r})")
                    continue
                effective_tgt = effective_target_repo_key(tgt, proj if proj else None)
                key = (src, effective_tgt)
                if key in seen:
                    continue
                seen.add(key)
                pairs.append(RepoPair(source_repo=src, target_repo=effective_tgt))
            return pairs
    except FileNotFoundError:
        print(f"CSV file {resolved} not found. Aborting.")
        return []
    except (OSError, csv.Error) as e:
        print(f"Failed to read CSV {resolved}: {e}")
        return []


def generate_cron_expression(hour, minute):
    """Generate cron expression for replication schedule."""
    return f"0 {minute} {hour} * * ?"


def _advance_schedule(hour, minute, interval_minutes):
    """Return (next_hour, next_minute) after advancing by interval_minutes."""
    minute += interval_minutes
    if minute >= 60:
        minute -= 60
        hour += 1
    if hour >= 24:
        hour = 0
    return hour, minute


def get_replication_payload(pair, cron_exp, config):
    """Build replication payload from config; target URL, proxy, checkBinaryExistenceAllowed as string.

    `pair` may be a RepoPair (source/target may differ) or a string (same-name flat-list mode).
    """
    src_key, tgt_key = _pair_keys(pair)
    replication_url = f"{config['TARGET_JPD_URL'].rstrip('/')}/artifactory/{tgt_key}/"
    return {
        "url": replication_url,
        "socketTimeoutMillis": config['SOCKET_TIMEOUT'],
        "username": config['REPLICATION_USERNAME'],
        "password": config['REPLICATION_PASSWORD'],
        "enableEventReplication": config['ENABLE_EVENT_REPLICATION'],
        "enabled": config['ENABLE_STATUS'],
        "cronExp": cron_exp,
        "syncDeletes": config['SYNC_DELETES'],
        "syncProperties": config['SYNC_PROPERTIES'],
        "syncStatistics": config['SYNC_STATISTICS'],
        "proxy": config['PROXY_NAME'],
        "checkBinaryExistenceAllowed": "true",
        "repoKey": src_key,
    }


def _pair_keys(pair):
    """Return (source_repo, target_repo) for a RepoPair or a plain string repo key."""
    if isinstance(pair, RepoPair):
        return pair.source_repo, pair.target_repo
    return pair, pair


def _format_pair(pair):
    src_key, tgt_key = _pair_keys(pair)
    if src_key == tgt_key:
        return f"{src_key}"
    return f"{src_key} -> {tgt_key}"


def create_replication_config(pair, cron_exp, config):
    """Create replication configuration using PUT (Set Repository Replication Configuration API)."""
    src_key, _tgt_key = _pair_keys(pair)
    payload = get_replication_payload(pair, cron_exp, config)
    label = _format_pair(pair)

    print(f"[Dry Run] Would create replication for {label} with CRON: {cron_exp}" if config['DRY_RUN'] else f"Creating replication for {label} with CRON: {cron_exp}")

    if not config['DRY_RUN']:
        if _put_replication(src_key, payload, config):
            print(f"✓ Replication configuration created successfully for repo: {label}")
            return True
        return False
    return True


def update_replication_config(pair, cron_exp, config):
    """Update replication configuration using POST (Update Repository Replication Configuration API)."""
    src_key, _tgt_key = _pair_keys(pair)
    url = f"{config['SOURCE_JPD_URL'].rstrip('/')}/artifactory/api/replications/{src_key}"
    headers = get_headers(config)
    payload = get_replication_payload(pair, cron_exp, config)
    label = _format_pair(pair)

    print(f"[Dry Run] Would update replication for {label} with CRON: {cron_exp}" if config['DRY_RUN'] else f"Updating replication for {label} with CRON: {cron_exp}")

    if not config['DRY_RUN']:
        try:
            response = requests.post(url, headers=headers, data=json.dumps(payload), timeout=10)
            response.raise_for_status()
            print(f"✓ Replication configuration updated successfully for repo: {label}")
            return True
        except requests.exceptions.RequestException as e:
            print(f"✗ Failed to update replication for repo {label}: {e}")
            if hasattr(e, 'response') and e.response is not None:
                print(f"  Response status: {e.response.status_code}")
                print(f"  Response body: {e.response.text}")
            return False
    return True


def get_replication_status(pair, config):
    """Get the status of a replication configuration (Scheduled Replication Status API)."""
    src_key, _tgt_key = _pair_keys(pair)
    label = _format_pair(pair)
    print(f"Getting replication status for {label}...")
    data = _fetch_replication_config(src_key, config)
    if data is not None:
        print(f"\n✓ Replication status for {label}:")
        print(json.dumps(data, indent=2))
        return True
    return False


def execute_immediate_replication(pair, config):
    """Execute an immediate push replication (Push Replication API).
    Uses POST artifactory/api/replication/execute/{repoPath} per JFrog REST API.
    """
    src_key, _tgt_key = _pair_keys(pair)
    base = config['SOURCE_JPD_URL'].rstrip('/')
    execute_url = f"{base}/artifactory/api/replication/execute/{src_key}"
    headers = get_headers(config)
    label = _format_pair(pair)
    print(f"[Dry Run] Would execute immediate replication for {label}" if config['DRY_RUN'] else f"Executing immediate replication for {label}...")
    if not config['DRY_RUN']:
        try:
            response = requests.post(execute_url, headers=headers, timeout=30)
            response.raise_for_status()
            print(f"✓ Immediate replication executed successfully for repo: {label}")
            if response.text:
                print(f"  Response: {response.text}")
            return True
        except requests.exceptions.RequestException as e:
            print(f"✗ Failed to execute immediate replication for repo {label}: {e}")
            if hasattr(e, 'response') and e.response is not None:
                print(f"  Response status: {e.response.status_code}")
                print(f"  Response body: {e.response.text}")
            return False
    return True


def delete_replication_config(pair, config):
    """Delete a replication configuration (Delete Repository Replication Configuration API)."""
    src_key, _tgt_key = _pair_keys(pair)
    url = f"{config['SOURCE_JPD_URL'].rstrip('/')}/artifactory/api/replications/{src_key}"
    headers = get_headers(config)
    label = _format_pair(pair)
    print(f"[Dry Run] Would delete replication for {label}" if config['DRY_RUN'] else f"Deleting replication for {label}...")
    if not config['DRY_RUN']:
        try:
            response = requests.delete(url, headers=headers, timeout=10)
            response.raise_for_status()
            print(f"✓ Replication configuration deleted successfully for repo: {label}")
            return True
        except requests.exceptions.RequestException as e:
            print(f"✗ Failed to delete replication for repo {label}: {e}")
            if hasattr(e, 'response') and e.response is not None:
                print(f"  Response status: {e.response.status_code}")
                print(f"  Response body: {e.response.text}")
            return False
    return True


def _resolve_pairs(config, single_repo):
    """Build the list of repo pairs for this run.

    Resolution order:
      1. CSV mode (--csv / CSV_PATH): rows from the CSV. If --repo is also set, filter by source key.
      2. Flat list mode (default): one repo per line in REPO_LIST_FILE; --repo overrides as a single entry.
    """
    csv_path = (config.get('CSV_PATH') or '').strip()
    if csv_path:
        pairs = get_repo_pairs_from_csv(
            csv_path, config['COL_SOURCE'], config['COL_TARGET'], config['COL_PROJECT']
        )
        if single_repo:
            pairs = [p for p in pairs if p.source_repo == single_repo]
            if not pairs:
                print(f"--repo {single_repo!r} not found in CSV column {config['COL_SOURCE']!r}.")
        return pairs
    if single_repo:
        return [single_repo]
    return get_repositories_from_file(config['REPO_LIST_FILE'])


# ---------------------------------------------------------------------------
# New operations: backup, restore, disable, enable
# ---------------------------------------------------------------------------

def backup_replication(repo_key, config):
    """Back up the replication config for one repo to <backup-dir>/<repo>.json.

    Returns True on success, False on failure.
    """
    backup_dir = _resolve_path(config['BACKUP_DIR'])
    out_path = os.path.join(backup_dir, f"{repo_key}.json")

    if config['DRY_RUN']:
        print(f"[Dry Run] Would back up replication config for {repo_key} → {out_path}")
        return True

    data = _fetch_replication_config(repo_key, config)
    if data is None:
        return False

    os.makedirs(backup_dir, exist_ok=True)
    with open(out_path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"✓ Backed up replication config for {repo_key} → {out_path}")
    return True


def restore_replication_config(repo_key, config):
    """Restore a replication config to the source JPD from a backed-up JSON file.

    Reads <backup-dir>/<repo>.json, rewrites the 'url' field(s) to point to the
    target JPD, optionally overrides 'enabled', then PUTs the payload verbatim.
    Returns True on success, False on failure.
    """
    backup_dir = _resolve_path(config['BACKUP_DIR'])
    backup_file = os.path.join(backup_dir, f"{repo_key}.json")

    if not os.path.exists(backup_file):
        print(f"✗ Backup file not found: {backup_file}")
        return False

    with open(backup_file, 'r') as f:
        original = json.load(f)

    target_base = config['TARGET_JPD_URL'].rstrip('/')

    def _patch_entry(entry):
        """Rewrite the replication URL to point to the target JPD and apply enabled override."""
        patched = dict(entry)
        old_url = patched.get('url', '')
        if old_url:
            marker = '/artifactory/'
            idx = old_url.find(marker)
            repo_path = old_url[idx + len(marker):] if idx != -1 else f"{repo_key}/"
            patched['url'] = f"{target_base}{marker}{repo_path}"
        if config.get('ENABLED_OVERRIDE') is not None:
            patched['enabled'] = config['ENABLED_OVERRIDE']
        return patched

    if isinstance(original, list):
        payload = [_patch_entry(e) for e in original]
    else:
        payload = _patch_entry(original)

    if config['DRY_RUN']:
        print(f"[Dry Run] Would restore replication for {repo_key} from {backup_file}")
        print(f"  Target URL would be rewritten to: {target_base}/artifactory/...")
        if config.get('ENABLED_OVERRIDE') is not None:
            print(f"  enabled would be overridden to: {config['ENABLED_OVERRIDE']}")
        return True

    print(f"Restoring replication for {repo_key} from {backup_file}...")
    if _put_replication(repo_key, payload, config):
        print(f"✓ Replication configuration restored successfully for repo: {repo_key}")
        return True
    return False


def _toggle_replication(repo_key, enabled, config):
    """Enable or disable push replication for a repo by fetching its current config
    and re-PUTting it with only the `enabled` field changed.

    This preserves all existing settings (cron, sync flags, etc.).
    Returns True on success, False on failure.
    """
    verb = "enable" if enabled else "disable"
    verb_ing = "Enabling" if enabled else "Disabling"
    if config['DRY_RUN']:
        print(f"[Dry Run] Would {verb} replication for {repo_key}...")
        return True

    print(f"{verb_ing} replication for {repo_key}...")
    data = _fetch_replication_config(repo_key, config)
    if data is None:
        return False

    def _set_enabled_state(entry):
        patched = dict(entry)
        patched['enabled'] = enabled
        return patched

    payload = [_set_enabled_state(e) for e in data] if isinstance(data, list) else _set_enabled_state(data)

    if _put_replication(repo_key, payload, config):
        print(f"✓ Replication {'enabled' if enabled else 'disabled'} for repo: {repo_key}")
        return True
    return False


def disable_replication(repo_key, config):
    """Disable push replication for a repo (preserves all other settings)."""
    return _toggle_replication(repo_key, False, config)


def enable_replication(repo_key, config):
    """Enable push replication for a repo (preserves all other settings)."""
    return _toggle_replication(repo_key, True, config)


# ---------------------------------------------------------------------------
# Batch processor
# ---------------------------------------------------------------------------

def process_repos(command, config, single_repo=None):
    """Run command across one repo or all repos from file/CSV/discovery.

    - backup: auto-discovers repos via API (or uses --repo-list if explicitly set).
    - restore: lists JSON files from backup-dir.
    - create/update/get-status/immediate-execution/delete/disable/enable:
      uses _resolve_pairs which handles CSV mode and flat-list mode.
    """
    if command == 'backup':
        if single_repo:
            repos = [single_repo]
        else:
            file_repos = get_repositories_from_file(config['REPO_LIST_FILE']) if config.get('REPO_LIST_FILE') and config['REPO_LIST_FILE'] != 'local_repos.txt' else []
            if file_repos:
                repos = file_repos
            else:
                print("Auto-discovering repos with push replications...")
                repos = _discover_replicated_repos(config)
                if repos:
                    print(f"Found {len(repos)} repo(s) with push replication configured.")
                else:
                    print("No repos with push replication found.")
    elif command == 'restore':
        if single_repo:
            repos = [single_repo]
        else:
            backup_dir = _resolve_path(config['BACKUP_DIR'])
            if not os.path.isdir(backup_dir):
                print(f"Backup directory not found: {backup_dir}")
                return
            repos = [
                os.path.splitext(f)[0]
                for f in os.listdir(backup_dir)
                if f.endswith('.json')
            ]
            if not repos:
                print(f"No backup files found in {backup_dir}")
                return
            print(f"Found {len(repos)} backup file(s) in {backup_dir}")
    else:
        repos = _resolve_pairs(config, single_repo)

    if not repos:
        print("No repositories found to process.")
        return

    total_count = len(repos)
    success_count = 0
    current_hour = config['start_hour']
    current_minute = config['start_minute']
    interval_minutes = config['interval_minutes']

    if command in ('create', 'update'):
        fn = create_replication_config if command == 'create' else update_replication_config
        for repo in repos:
            cron_exp = generate_cron_expression(current_hour, current_minute)
            if fn(repo, cron_exp, config):
                success_count += 1
            current_hour, current_minute = _advance_schedule(current_hour, current_minute, interval_minutes)
    else:
        for repo in repos:
            if command == 'get-status':
                if get_replication_status(repo, config):
                    success_count += 1
            elif command == 'immediate-execution':
                if execute_immediate_replication(repo, config):
                    success_count += 1
            elif command == 'delete':
                if delete_replication_config(repo, config):
                    success_count += 1
            elif command == 'backup':
                if backup_replication(repo, config):
                    success_count += 1
            elif command == 'restore':
                if restore_replication_config(repo, config):
                    success_count += 1
            elif command == 'disable':
                if disable_replication(repo, config):
                    success_count += 1
            elif command == 'enable':
                if enable_replication(repo, config):
                    success_count += 1

    print(f"\n{'Dry run completed!' if config['DRY_RUN'] else f'Operation completed: {success_count}/{total_count} repositories processed successfully.'}")


def main():
    command, single_repo, config = parse_arguments()

    if config['DRY_RUN']:
        print("Running in DRY RUN mode - no changes will be made\n")

    # For restore: --enabled CLI flag acts as an override on top of the backup.
    # Store it separately so _patch_entry can distinguish "not set" from false.
    if command == 'restore':
        # args.enabled was already resolved into config['ENABLE_STATUS'] but we
        # need to know if the user explicitly passed --enabled. Re-check by
        # seeing if ENABLE_STATUS differs from the default (True). We use a
        # sentinel in config so restore_replication_config can read it cleanly.
        import sys
        enabled_explicitly_set = '--enabled' in sys.argv
        config['ENABLED_OVERRIDE'] = config['ENABLE_STATUS'] if enabled_explicitly_set else None
    else:
        config['ENABLED_OVERRIDE'] = None

    if command in ('create', 'update'):
        csv_path = (config.get('CSV_PATH') or '').strip()
        print(f"Configuration:")
        print(f"  Source JPD: {config['SOURCE_JPD_URL']}")
        print(f"  Target JPD: {config['TARGET_JPD_URL']}")
        print(f"  Start time: {config['start_hour']:02d}:{config['start_minute']:02d}")
        print(f"  Interval: {config['interval_minutes']} minutes")
        print(f"  Dry run: {config['DRY_RUN']}")
        if csv_path:
            print(f"  CSV: {csv_path} (columns: {config['COL_SOURCE']}, {config['COL_TARGET']}, {config['COL_PROJECT']})")
        pairs = _resolve_pairs(config, single_repo)
        if single_repo and not csv_path:
            print(f"  Repository: {single_repo}")
        else:
            print(f"  Repositories: {len(pairs)}")
            for p in pairs[:5]:
                print(f"    - {_format_pair(p)}")
            if len(pairs) > 5:
                print(f"    ... and {len(pairs) - 5} more")
        print()
    elif command == 'backup':
        print(f"Configuration:")
        print(f"  Source JPD: {config['SOURCE_JPD_URL']}")
        print(f"  Backup dir: {_resolve_path(config['BACKUP_DIR'])}")
        print(f"  Dry run: {config['DRY_RUN']}")
        print()
    elif command == 'restore':
        print(f"Configuration:")
        print(f"  Target JPD: {config['SOURCE_JPD_URL']} (restore destination)")
        print(f"  Replication target URL: {config['TARGET_JPD_URL']}")
        print(f"  Backup dir: {_resolve_path(config['BACKUP_DIR'])}")
        enabled_override = config.get('ENABLED_OVERRIDE')
        if enabled_override is not None:
            print(f"  Enabled override: {enabled_override}")
        print(f"  Dry run: {config['DRY_RUN']}")
        print()

    process_repos(command, config, single_repo=single_repo)


if __name__ == "__main__":
    main()
