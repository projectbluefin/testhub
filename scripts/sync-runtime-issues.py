#!/usr/bin/env python3
"""
Sync runtime-update issues from ublue-os/flatpak-tracker into testhub.

Usage:
  python3 scripts/sync-runtime-issues.py [--dry-run]

Reads:
  GITHUB_TOKEN env var (optional for local dry-run; required in CI to avoid rate limiting)

For each open runtime-update issue in flatpak-tracker, opens one testhub issue
(if not already open) with all labels from the tracker issue mirrored.
When a tracker issue closes, closes the matching testhub issue.
"""

import argparse
import os
import re
from pathlib import Path
from urllib.parse import quote

import requests
import yaml

PROTECTED_DIRS = {
    "ghostty",
    "goose",
    "lmstudio",
    "firefox-nightly",
    "thunderbird-nightly",
    "virtualbox",
}
FLATPAK_TRACKER_REPO = "ublue-os/flatpak-tracker"
TESTHUB_REPO = os.environ.get("GITHUB_REPOSITORY", "projectbluefin/testhub")
FLATPAKS_DIR = Path("flatpaks")

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
# Use token only for flathub/ and testhub API calls; flatpak-tracker is public
# and a repo-scoped GITHUB_TOKEN may be rejected cross-org, returning empty results.
HEADERS = {"Authorization": f"Bearer {GITHUB_TOKEN}"} if GITHUB_TOKEN else {}
HEADERS_PUBLIC = {
    "User-Agent": "testhub-sync/1.0 (github.com/projectbluefin/testhub)"
}  # no auth — for cross-org public repos (ublue-os/flatpak-tracker)


def get_tracker_issues(state: str) -> list[dict]:
    """Fetch flatpak-tracker issues labeled runtime."""
    seen: dict[int, dict] = {}
    page = 1
    while True:
        url = (
            f"https://api.github.com/repos/{FLATPAK_TRACKER_REPO}/issues"
            f"?labels=runtime&state={state}&per_page=100&page={page}"
        )
        resp = requests.get(url, headers=HEADERS_PUBLIC, timeout=30)
        if resp.status_code == 404:
            print(f"WARNING: flatpak-tracker repo not found or no access: {url}")
            break
        resp.raise_for_status()
        batch = resp.json()
        if not batch:
            break
        for issue in batch:
            issue_num = issue["number"]
            if issue_num not in seen:
                seen[issue_num] = issue
        if len(batch) < 100:
            break
        page += 1
    return list(seen.values())


def parse_issue_body(body: str) -> dict | None:
    """Extract app_id, current_runtime, and target_version from issue body.

    Returns None if required fields are not found.
    """
    if not body:
        return None

    # **Package:** line → app_id
    pkg_match = re.search(r"\*\*Package:\*\*\s*(.+)", body)
    if not pkg_match:
        return None
    raw_pkg = pkg_match.group(1).strip().strip("`")
    # Strip leading app/ prefix (e.g. app/com.foo.Bar → com.foo.Bar)
    app_id = re.sub(r"^app/", "", raw_pkg)

    # **Current Runtime:** line → e.g. org.gnome.Platform//48
    current_match = re.search(r"\*\*Current Runtime:\*\*\s*(.+)", body)
    current_runtime = (
        current_match.group(1).strip().strip("`") if current_match else None
    )

    # **Latest Available Runtime:** line → e.g. org.gnome.Platform/x86_64/49
    # or org.gnome.Platform//49 (spec says //, real data uses /)
    latest_match = re.search(r"\*\*Latest Available Runtime:\*\*\s*(.+)", body)
    if not latest_match:
        return None
    latest_runtime = latest_match.group(1).strip().strip("`")

    # Extract version number — last segment after / or //
    version_match = re.search(r"[/]{1,2}([^/`\s]+)\s*$", latest_runtime)
    if not version_match:
        return None
    target_version = version_match.group(1).strip()

    return {
        "app_id": app_id,
        "current_runtime": current_runtime,
        "target_version": target_version,
    }


def is_protected(app_id: str) -> bool:
    """Return True if app_id matches a protected app (skip it)."""
    # Check directory name (last segment of app_id)
    dir_name = app_id.lower().split(".")[-1]
    if dir_name in PROTECTED_DIRS:
        return True
    # Check exact match against directory names
    for d in PROTECTED_DIRS:
        if d == app_id.lower():
            return True
    # Check existing manifests: read app-id field from each protected app's manifest.yaml
    for pdir in PROTECTED_DIRS:
        manifest_path = FLATPAKS_DIR / pdir / "manifest.yaml"
        if manifest_path.exists():
            try:
                with open(manifest_path) as f:
                    data = yaml.safe_load(f)
                if data and data.get("app-id", "").lower() == app_id.lower():
                    return True
            except Exception:
                pass
    return False


def _api(method: str, path: str, **kwargs) -> requests.Response:
    """Make an authenticated GitHub API call to TESTHUB_REPO."""
    url = f"https://api.github.com/repos/{TESTHUB_REPO}/{path}"
    return requests.request(method, url, headers=HEADERS, timeout=30, **kwargs)


def ensure_label(name: str, color: str, description: str, dry_run: bool) -> None:
    """Create label in testhub if it doesn't already exist."""
    resp = _api("GET", f"labels/{quote(name, safe='')}")
    if resp.status_code == 200:
        return  # already exists
    if dry_run:
        print(f"    DRY-RUN LABEL: would create '{name}' (#{color})")
        return
    _api(
        "POST",
        "labels",
        json={"name": name, "color": color, "description": description or ""},
    )
    print(f"    LABEL CREATED: {name}")


def find_open_testhub_issue(app_id: str) -> int | None:
    """Return number of an open testhub issue for app_id, or None."""
    search_title = f"runtime-update: {app_id}"
    resp = requests.get(
        "https://api.github.com/search/issues",
        headers=HEADERS,
        params={
            "q": f'repo:{TESTHUB_REPO} is:issue is:open "{search_title}" in:title',
            "per_page": 1,
        },
        timeout=30,
    )
    if not resp.ok:
        return None
    items = resp.json().get("items", [])
    return items[0]["number"] if items else None


def find_open_testhub_issue_by_app(app_id: str) -> dict | None:
    """Return the open testhub issue dict for app_id (runtime-update), or None."""
    search_title = f"runtime-update: {app_id}"
    resp = requests.get(
        "https://api.github.com/search/issues",
        headers=HEADERS,
        params={
            "q": f'repo:{TESTHUB_REPO} is:issue is:open "{search_title}" in:title',
            "per_page": 1,
        },
        timeout=30,
    )
    if not resp.ok:
        return None
    items = resp.json().get("items", [])
    return items[0] if items else None


def open_issue_for_app(
    app_id: str,
    issue_num: int,
    current_runtime: str | None,
    target_version: str,
    tracker_issue_url: str,
    label_objects: list[dict],
    dry_run: bool,
) -> bool:
    """Open a testhub issue for a runtime-update, mirroring all labels from tracker.

    Returns True if an issue was opened (or would be in dry-run), False if skipped.
    Skips if an open issue for this app already exists.
    """
    existing = find_open_testhub_issue(app_id)
    if existing:
        print(f"    ISSUE: #{existing} already open for {app_id} — skipping")
        return False

    title = f"runtime-update: {app_id}"
    current_line = (
        f"- **Current runtime:** `{current_runtime}`\n" if current_runtime else ""
    )
    body = (
        f"Runtime update needed for `{app_id}`.\n\n"
        f"- **Tracker issue:** [ublue-os/flatpak-tracker#{issue_num}]({tracker_issue_url})\n"
        f"{current_line}"
        f"- **Target runtime-version:** `{target_version}`\n\n"
        f"Labels mirrored from flatpak-tracker. Auto-filed by raptor[bot]."
    )

    label_names = [lbl["name"] for lbl in label_objects]

    if dry_run:
        print(f"    DRY-RUN ISSUE: would open '{title}' with labels {label_names}")
        return True

    # Ensure all labels exist in testhub
    for lbl in label_objects:
        ensure_label(
            lbl["name"],
            lbl.get("color", "ededed"),
            lbl.get("description", ""),
            dry_run=False,
        )

    resp = _api(
        "POST", "issues", json={"title": title, "body": body, "labels": label_names}
    )
    if resp.ok:
        num = resp.json()["number"]
        print(f"    ISSUE OPENED: #{num} — {title}")
        return True
    else:
        print(
            f"    ERROR: could not open issue for {app_id}: {resp.status_code} {resp.text[:200]}"
        )
        return False


def close_testhub_issue(issue_number: int, app_id: str, dry_run: bool) -> None:
    """Close a testhub issue."""
    if dry_run:
        print(f"    DRY-RUN CLOSE: would close issue #{issue_number} for {app_id}")
        return
    _api("PATCH", f"issues/{issue_number}", json={"state": "closed"})
    print(f"    ISSUE CLOSED: #{issue_number} for {app_id}")


def process_open_issues(issues: list[dict], dry_run: bool) -> dict:
    """Process open runtime-update issues. Returns summary counts."""
    counts = {
        "opened": 0,
        "skipped": 0,
        "already_open": 0,
        "errors": 0,
    }

    for issue in issues:
        issue_num = issue["number"]
        issue_labels = issue.get("labels", [])
        issue_label_names = [lbl["name"] for lbl in issue_labels]

        # Skip: dont-bother label
        if "dont-bother" in issue_label_names:
            print(f"  SKIP #{issue_num}: has dont-bother label")
            counts["skipped"] += 1
            continue

        parsed = parse_issue_body(issue.get("body", ""))
        if not parsed:
            print(f"  SKIP #{issue_num}: could not parse body")
            counts["skipped"] += 1
            continue

        app_id = parsed["app_id"]
        target_version = parsed["target_version"]
        current_runtime = parsed.get("current_runtime")

        print(f"  Issue #{issue_num}: {app_id} → runtime-version {target_version}")

        # Skip protected apps
        if is_protected(app_id):
            print(f"    SKIP: protected app")
            counts["skipped"] += 1
            continue

        tracker_url = issue.get("html_url", "")

        if not GITHUB_TOKEN:
            print("    NOTE: GITHUB_TOKEN not set — skipping issue creation")
            counts["skipped"] += 1
            continue

        try:
            opened = open_issue_for_app(
                app_id,
                issue_num,
                current_runtime,
                target_version,
                tracker_url,
                issue_labels,
                dry_run,
            )
            if opened:
                counts["opened"] += 1
            else:
                counts["already_open"] += 1
        except Exception as e:
            print(f"    ERROR: {e}")
            counts["errors"] += 1

    return counts


def process_closed_issues(issues: list[dict], dry_run: bool) -> int:
    """Close testhub issues for tracker issues that are now closed. Returns close count."""
    closed = 0
    for issue in issues:
        issue_num = issue["number"]
        parsed = parse_issue_body(issue.get("body", ""))
        if not parsed:
            continue
        app_id = parsed["app_id"]
        if is_protected(app_id):
            continue
        if not GITHUB_TOKEN:
            continue
        existing = find_open_testhub_issue_by_app(app_id)
        if existing:
            close_testhub_issue(existing["number"], app_id, dry_run)
            closed += 1
    return closed


def main():
    parser = argparse.ArgumentParser(
        description="Sync runtime-update issues from flatpak-tracker into testhub."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print all actions but do not open or close any issues.",
    )
    args = parser.parse_args()

    if args.dry_run:
        print("=== DRY-RUN MODE: no issues will be created or closed ===\n")

    if not GITHUB_TOKEN:
        print(
            "WARNING: GITHUB_TOKEN not set — unauthenticated requests may be rate-limited\n"
        )

    # === Open issues: open testhub issues ===
    print("Fetching open flatpak-tracker issues (runtime label)...")
    open_issues = get_tracker_issues("open")
    print(f"Found {len(open_issues)} unique open issues\n")

    if open_issues:
        print("Processing open issues:")
        counts = process_open_issues(open_issues, args.dry_run)
    else:
        print("No open runtime-update issues found.")
        counts = {"opened": 0, "skipped": 0, "already_open": 0, "errors": 0}

    # === Closed issues: close matching testhub issues ===
    print("\nFetching closed flatpak-tracker issues (runtime label)...")
    closed_issues = get_tracker_issues("closed")
    print(f"Found {len(closed_issues)} unique closed issues\n")

    if closed_issues:
        print("Processing closed issues:")
        closed_count = process_closed_issues(closed_issues, args.dry_run)
    else:
        closed_count = 0

    # === Summary ===
    print("\n=== Summary ===")
    print(f"  Open tracker issues   : {len(open_issues)}")
    print(f"  Testhub issues opened : {counts['opened']}")
    print(f"  Already open (skip)   : {counts['already_open']}")
    print(f"  Skipped               : {counts['skipped']}")
    print(f"  Errors                : {counts['errors']}")
    print(f"  Testhub issues closed : {closed_count}")
    if args.dry_run:
        print("\n(dry-run: no issues were created or closed)")


if __name__ == "__main__":
    main()
