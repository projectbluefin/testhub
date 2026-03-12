#!/usr/bin/env python3
"""
Sync runtime-update issues from ublue-os/flatpak-tracker into testhub.

Usage:
  python3 scripts/sync-runtime-issues.py [--dry-run]

Reads:
  GITHUB_TOKEN env var (optional for local dry-run; required in CI to avoid rate limiting)

Writes:
  flatpaks/<app-id>/manifest.yaml  for each open runtime-update issue
  (sets x-disabled: true in manifest.yaml when upstream issue closes)
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

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


def is_already_up_to_date(app_id: str, target_version: str) -> bool:
    """Return True if flatpaks/<app_id>/manifest.yaml already has the target runtime-version."""
    manifest_path = FLATPAKS_DIR / app_id / "manifest.yaml"
    if not manifest_path.exists():
        return False
    try:
        with open(manifest_path) as f:
            data = yaml.safe_load(f)
        if data and str(data.get("runtime-version", "")) == str(target_version):
            return True
    except Exception:
        pass
    return False


def find_runtime_bump_pr(app_id: str) -> dict | None:
    """Fetch open Flathub PRs for app_id; return manifest data from PR branch if found."""
    url = f"https://api.github.com/repos/flathub/{app_id}/pulls?state=open&per_page=50"
    resp = requests.get(url, headers=HEADERS, timeout=30)
    if resp.status_code == 404:
        return None
    if not resp.ok:
        return None
    prs = resp.json()
    for pr in prs:
        title = pr.get("title", "")
        if "runtime" not in title.lower():
            continue
        head = pr.get("head", {})
        head_repo = head.get("repo") or {}
        full_name = head_repo.get("full_name", "")
        ref = head.get("ref", "")
        if not full_name or not ref:
            continue
        for ext, is_json in ((".json", True), (".yml", False), (".yaml", False)):
            manifest_url = (
                f"https://raw.githubusercontent.com/{full_name}/{ref}/{app_id}{ext}"
            )
            mresp = requests.get(manifest_url, timeout=30)
            if mresp.status_code != 200:
                continue
            try:
                data = mresp.json() if is_json else yaml.safe_load(mresp.text)
                if data:
                    return data
            except Exception:
                continue
    return None


def fetch_flathub_manifest(app_id: str) -> tuple[dict | None, str]:
    """Fetch the Flathub manifest from the default branch (master, then main).

    Tries .json first, then .yml, then .yaml.
    Returns (manifest_data, branch) or (None, "").
    """
    for branch in ("master", "main"):
        for ext in (".json", ".yml", ".yaml"):
            url = f"https://raw.githubusercontent.com/flathub/{app_id}/{branch}/{app_id}{ext}"
            resp = requests.get(url, timeout=30)
            if resp.status_code != 200:
                continue
            try:
                if ext == ".json":
                    return resp.json(), branch
                else:
                    return yaml.safe_load(resp.text), branch
            except Exception:
                continue
    return None, ""


def flathub_repo_exists(app_id: str) -> bool:
    """Return True if the Flathub repo exists."""
    url = f"https://api.github.com/repos/flathub/{app_id}"
    resp = requests.get(url, headers=HEADERS, timeout=30)
    return resp.status_code == 200


def build_manifest_content(data: dict, issue_number: int) -> str:
    """Convert JSON manifest dict to YAML string with injected fields and header comment."""
    # Inject x-version and x-arches into the data dict
    data["x-version"] = ""
    data["x-arches"] = ["x86_64"]

    header = f"# Auto-imported from flatpak-tracker issue #{issue_number} — do not edit manually\n"
    content = header + yaml.dump(
        data, sort_keys=False, allow_unicode=True, default_flow_style=False
    )
    return content


def fetch_local_patch_files(
    app_id: str, manifest_data: dict, branch: str, dry_run: bool
) -> list[str]:
    """Fetch local patch files referenced in manifest modules and write them to flatpaks/<app_id>/.

    Scans all modules recursively for sources of type 'patch' with a 'path' field (not a URL).
    Returns list of fetched file paths.
    """
    fetched: list[str] = []
    patch_paths: list[str] = []

    # Collect all patch source paths recursively from modules
    def collect_patches(modules):
        if not modules:
            return
        for mod in modules:
            if not isinstance(mod, dict):
                continue
            for src in mod.get("sources", []):
                if not isinstance(src, dict):
                    continue
                if src.get("type") == "patch":
                    path = src.get("path", "")
                    # Only local paths (not URLs)
                    if (
                        path
                        and not path.startswith("http://")
                        and not path.startswith("https://")
                    ):
                        patch_paths.append(path)
            # Recurse into submodules
            collect_patches(mod.get("modules", []))

    collect_patches(manifest_data.get("modules", []))

    if not patch_paths:
        return fetched

    target_dir = FLATPAKS_DIR / app_id

    for patch_path in patch_paths:
        # patch_path is relative to the manifest — fetch from the same directory in the Flathub repo
        patch_name = Path(patch_path).name
        raw_url = (
            f"https://raw.githubusercontent.com/flathub/{app_id}/{branch}/{patch_path}"
        )
        print(f"    PATCH: fetching {patch_path} from {raw_url}")

        if dry_run:
            print(f"    DRY-RUN PATCH WRITE: {target_dir / patch_name}")
            fetched.append(patch_name)
            continue

        try:
            resp = requests.get(raw_url, timeout=30)
            if resp.status_code != 200:
                print(
                    f"    WARNING: could not fetch {patch_path} (HTTP {resp.status_code}) — build may fail"
                )
                continue
            target_dir.mkdir(parents=True, exist_ok=True)
            dest = target_dir / patch_name
            dest.write_bytes(resp.content)
            print(f"    PATCH WRITTEN: {dest}")
            fetched.append(patch_name)
        except Exception as e:
            print(f"    WARNING: error fetching {patch_path}: {e}")

    return fetched


def write_manifest(app_id: str, content: str, dry_run: bool) -> bool:
    """Write manifest.yaml for app_id. Returns True if a write occurred."""
    target_dir = FLATPAKS_DIR / app_id
    target_path = target_dir / "manifest.yaml"

    # Check if content has changed
    if target_path.exists():
        existing = target_path.read_text()
        if existing == content:
            return False

    if dry_run:
        print(f"DRY-RUN WRITE: {target_path}")
        return True

    target_dir.mkdir(parents=True, exist_ok=True)
    target_path.write_text(content)

    # Write exceptions.json if not already present (appid-filename-mismatch is
    # always required since we use manifest.yaml not <app-id>.yaml)
    exceptions_path = target_dir / "exceptions.json"
    if not exceptions_path.exists():
        exceptions = {app_id: ["appid-filename-mismatch"]}
        exceptions_path.write_text(json.dumps(exceptions, indent=4) + "\n")

    return True


def retire_app(app_id: str, dry_run: bool) -> bool:
    """Add x-disabled: true to flatpaks/<app_id>/manifest.yaml. Returns True if written."""
    manifest_path = FLATPAKS_DIR / app_id / "manifest.yaml"
    if not manifest_path.exists():
        return False
    try:
        with open(manifest_path) as f:
            raw = f.read()
        data = yaml.safe_load(raw)
    except Exception as e:
        print(f"WARNING: could not read {manifest_path}: {e}")
        return False

    if data is None:
        return False
    if data.get("x-disabled") is True:
        return False  # already retired

    data["x-disabled"] = True

    # Preserve header comment if present
    header = ""
    if raw.startswith("#"):
        header = raw.split("\n")[0] + "\n"

    content = header + yaml.dump(
        data, sort_keys=False, allow_unicode=True, default_flow_style=False
    )

    if dry_run:
        print(f"DRY-RUN RETIRE: {manifest_path}")
        return True

    manifest_path.write_text(content)
    return True


def _git(*args: str) -> str:
    """Run a git command and return stdout. Raises on non-zero exit."""
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def _gh(*args: str) -> str:
    """Run a gh command and return stdout. Raises on non-zero exit."""
    env = os.environ.copy()
    env["GH_TOKEN"] = GITHUB_TOKEN
    result = subprocess.run(["gh", *args], capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def open_pr_for_app(
    app_id: str,
    issue_num: int,
    target_version: str,
    tracker_issue_url: str,
    dry_run: bool,
) -> bool:
    """Create a branch, commit the app dir, and open a PR for a single imported app.

    Returns True if a PR was opened (or would be in dry-run), False if skipped.
    Skips silently if an open PR for this app already exists on a raptor/runtime branch.
    """
    # Check for an existing open PR for this app to avoid duplicates
    existing = _gh(
        "pr",
        "list",
        "--state",
        "open",
        "--search",
        f"raptor/runtime-{app_id} in:title",
        "--json",
        "number",
        "--jq",
        '.[0].number // ""',
    )
    if existing:
        print(f"    PR: open PR #{existing} already exists for {app_id} — skipping")
        return False

    timestamp = time.strftime("%Y%m%d-%H%M%S")
    branch = f"raptor/runtime-{app_id}-{timestamp}"
    base_branch = _git("rev-parse", "--abbrev-ref", "HEAD")
    title = f"chore(flatpaks): runtime-update {app_id} → {target_version}"
    body = (
        f"Automated runtime-update sync from "
        f"[flatpak-tracker #{issue_num}]({tracker_issue_url}).\n\n"
        f"- App: `{app_id}`\n"
        f"- New runtime-version: `{target_version}`\n\n"
        f"Manifests imported by raptor[bot]. Each app builds independently."
    )

    if dry_run:
        print(f"    DRY-RUN PR: would open branch {branch} → PR '{title}'")
        return True

    _git("config", "user.name", "raptor[bot]")
    _git("config", "user.email", "noop@projectbluefin.dev")
    _git("checkout", "-b", branch)
    _git("add", str(FLATPAKS_DIR / app_id))
    _git("commit", "-m", title)
    _git("push", "origin", branch)
    _gh(
        "pr",
        "create",
        "--title",
        title,
        "--body",
        body,
        "--base",
        base_branch,
        "--head",
        branch,
    )
    # Return to base branch so subsequent apps branch off the same base
    _git("checkout", base_branch)
    print(f"    PR: opened branch {branch}")
    return True


def open_pr_for_retirement(app_id: str, issue_num: int, dry_run: bool) -> bool:
    """Create a branch, commit the x-disabled change, and open a PR for a retired app.

    Returns True if a PR was opened.
    """
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    branch = f"raptor/retire-{app_id}-{timestamp}"
    base_branch = _git("rev-parse", "--abbrev-ref", "HEAD")
    title = f"chore(flatpaks): retire {app_id} (tracker #{issue_num} closed)"
    body = (
        f"Flatpak-tracker issue #{issue_num} was closed, indicating the runtime-update "
        f"is no longer pending for `{app_id}`.\n\n"
        f"Sets `x-disabled: true` in the manifest so the app is skipped by build and "
        f"push jobs until manually re-enabled or removed.\n\n"
        f"Auto-filed by raptor[bot]."
    )

    if dry_run:
        print(f"    DRY-RUN RETIRE PR: would open branch {branch} → PR '{title}'")
        return True

    _git("config", "user.name", "raptor[bot]")
    _git("config", "user.email", "noop@projectbluefin.dev")
    _git("checkout", "-b", branch)
    _git("add", str(FLATPAKS_DIR / app_id))
    _git("commit", "-m", title)
    _git("push", "origin", branch)
    _gh(
        "pr",
        "create",
        "--title",
        title,
        "--body",
        body,
        "--base",
        base_branch,
        "--head",
        branch,
    )
    _git("checkout", base_branch)
    print(f"    RETIRE PR: opened branch {branch}")
    return True


def process_open_issues(issues: list[dict], dry_run: bool) -> dict:
    """Process open runtime-update issues. Returns summary counts."""
    counts = {
        "imported": 0,
        "skipped": 0,
        "up_to_date": 0,
        "no_manifest": 0,
        "errors": 0,
    }

    for issue in issues:
        issue_num = issue["number"]
        issue_labels = [lbl["name"] for lbl in issue.get("labels", [])]

        # Skip: dont-bother label
        if "dont-bother" in issue_labels:
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

        print(f"  Issue #{issue_num}: {app_id} → runtime-version {target_version}")

        # Skip protected apps
        if is_protected(app_id):
            print(f"    SKIP: protected app")
            counts["skipped"] += 1
            continue

        # Skip if already up to date
        if is_already_up_to_date(app_id, target_version):
            print(f"    SKIP: already at runtime-version {target_version}")
            counts["up_to_date"] += 1
            continue

        # Check Flathub repo exists
        if not flathub_repo_exists(app_id):
            print(f"    SKIP: flathub/{app_id} not found (404)")
            counts["no_manifest"] += 1
            continue

        # Approach B: try runtime-bump PR branch first
        manifest_data = find_runtime_bump_pr(app_id)
        source = "flathub PR branch"
        flathub_branch = "master"  # default for patch-file fetching

        if manifest_data is None:
            # Fallback: fetch default branch and bump version
            manifest_data, flathub_branch = fetch_flathub_manifest(app_id)
            source = "flathub default branch (bumped)"
            if manifest_data is None:
                print(f"    ERROR: could not fetch manifest from flathub/{app_id}")
                counts["errors"] += 1
                continue
            # Inject target runtime-version
            manifest_data["runtime-version"] = target_version

        print(f"    SOURCE: {source}")

        # Ensure app-id is preserved (Flathub uses app-id, not id)
        if "id" in manifest_data and "app-id" not in manifest_data:
            manifest_data["app-id"] = manifest_data.pop("id")

        # Fetch any local patch files referenced in the manifest
        fetch_local_patch_files(app_id, manifest_data, flathub_branch, dry_run)

        content = build_manifest_content(manifest_data, issue_num)
        wrote = write_manifest(app_id, content, dry_run)

        if wrote:
            print(f"    IMPORT: {FLATPAKS_DIR / app_id / 'manifest.yaml'}")
            counts["imported"] += 1
            if GITHUB_TOKEN:
                tracker_url = issue.get("html_url", "")
                try:
                    open_pr_for_app(
                        app_id, issue_num, target_version, tracker_url, dry_run
                    )
                except RuntimeError as e:
                    print(f"    WARNING: could not open PR for {app_id}: {e}")
            else:
                print("    NOTE: GITHUB_TOKEN not set — skipping PR creation")
        else:
            print(f"    UNCHANGED: content identical, skipping write")
            counts["up_to_date"] += 1

    return counts


def process_retired_issues(issues: list[dict], dry_run: bool) -> int:
    """Process closed issues and retire matching manifests. Returns retire count."""
    retired = 0
    for issue in issues:
        issue_num = issue["number"]
        parsed = parse_issue_body(issue.get("body", ""))
        if not parsed:
            continue
        app_id = parsed["app_id"]
        if is_protected(app_id):
            continue
        if retire_app(app_id, dry_run):
            print(f"RETIRE: {app_id} (issue #{issue_num} closed)")
            retired += 1
            if GITHUB_TOKEN:
                try:
                    open_pr_for_retirement(app_id, issue_num, dry_run)
                except RuntimeError as e:
                    print(f"  WARNING: could not open retire PR for {app_id}: {e}")
    return retired


def main():
    parser = argparse.ArgumentParser(
        description="Sync runtime-update issues from flatpak-tracker into testhub."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print all actions but do not write any files.",
    )
    args = parser.parse_args()

    if args.dry_run:
        print("=== DRY-RUN MODE: no files will be written ===\n")

    if not GITHUB_TOKEN:
        print(
            "WARNING: GITHUB_TOKEN not set — unauthenticated requests may be rate-limited\n"
        )

    # === Open issues: import / update manifests ===
    print("Fetching open flatpak-tracker issues (runtime label)...")
    open_issues = get_tracker_issues("open")
    print(f"Found {len(open_issues)} unique open issues\n")

    if open_issues:
        print("Processing open issues:")
        counts = process_open_issues(open_issues, args.dry_run)
    else:
        print("No open runtime-update issues found.")
        counts = {
            "imported": 0,
            "skipped": 0,
            "up_to_date": 0,
            "no_manifest": 0,
            "errors": 0,
        }

    # === Closed issues: retire manifests ===
    print("\nFetching closed flatpak-tracker issues (runtime label)...")
    closed_issues = get_tracker_issues("closed")
    print(f"Found {len(closed_issues)} unique closed issues\n")

    if closed_issues:
        print("Processing closed issues (retirement check):")
        retired = process_retired_issues(closed_issues, args.dry_run)
    else:
        retired = 0

    # === Summary ===
    print("\n=== Summary ===")
    print(f"  Open issues processed : {len(open_issues)}")
    print(f"  Manifests imported    : {counts['imported']}")
    print(f"  Already up to date    : {counts['up_to_date']}")
    print(f"  Skipped               : {counts['skipped']}")
    print(f"  Flathub repo missing  : {counts['no_manifest']}")
    print(f"  Errors                : {counts['errors']}")
    print(f"  Retired (x-disabled)  : {retired}")
    if args.dry_run:
        print("\n(dry-run: no files were written)")


if __name__ == "__main__":
    main()
