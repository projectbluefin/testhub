#!/usr/bin/env python3
"""
Update jorgehub OCI index from skopeo inspect output.

Usage:
  update-index.py --app ghostty --digest sha256:abc123 --registry ghcr.io
  update-index.py --validate   # check existing index/static is valid JSON
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

INDEX_FILE = Path("index/static")

# Only ref and metadata are required — flatpak client needs these to discover and install the app.
# Size labels are optional; included when present, silently omitted when not.
REQUIRED_LABELS = [
    "org.flatpak.ref",
    "org.flatpak.metadata",
]

OPTIONAL_LABELS = [
    "org.flatpak.installed-size",
    "org.flatpak.download-size",
]


def load_index():
    if INDEX_FILE.exists():
        return json.loads(INDEX_FILE.read_text())
    return {"Registry": "https://ghcr.io", "Results": []}


def inspect_image(registry, repo, digest, tls_verify=True):
    tls_flag = [] if tls_verify else ["--tls-verify=false"]
    ref = f"docker://{registry}/{repo}@{digest}"
    result = subprocess.run(
        ["skopeo", "inspect"] + tls_flag + [ref],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def get_arch(inspect_data):
    return inspect_data.get("Architecture", "amd64")


def get_os(inspect_data):
    return inspect_data.get("Os", "linux")


def update_index(index, app, repo, digest, inspect_data, tags=None):
    """Idempotent: replace existing entry for this repo+arch or append."""
    labels = inspect_data.get("Labels", {})
    arch = get_arch(inspect_data)
    os_ = get_os(inspect_data)

    # Validate required labels
    missing = [k for k in REQUIRED_LABELS if k not in labels]
    if missing:
        print(f"ERROR: missing required labels: {missing}", file=sys.stderr)
        sys.exit(1)

    image_entry = {
        "Digest": digest,
        "MediaType": "application/vnd.oci.image.manifest.v1+json",
        "OS": os_,
        "Architecture": arch,
        "Tags": tags or ["latest"],
        "Labels": {
            k: labels[k] for k in REQUIRED_LABELS + OPTIONAL_LABELS if k in labels
        },
    }

    # Find or create result entry for this repo
    for result in index["Results"]:
        if result["Name"] == repo:
            # Replace image entry for this arch
            result["Images"] = [
                img for img in result["Images"] if img["Architecture"] != arch
            ]
            result["Images"].append(image_entry)
            return index

    # New repo entry
    index["Results"].append({"Name": repo, "Images": [image_entry]})
    return index


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", help="App name (e.g. ghostty)")
    parser.add_argument("--digest", help="Image digest (sha256:...)")
    parser.add_argument("--registry", default="ghcr.io")
    parser.add_argument(
        "--repo", help="Full repo path (default: castrojo/jorgehub/<app>)"
    )
    parser.add_argument("--tls-verify", action="store_true", default=True)
    parser.add_argument("--no-tls-verify", dest="tls_verify", action="store_false")
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--tags", nargs="+", default=["latest"])
    args = parser.parse_args()

    if args.validate:
        data = json.loads(INDEX_FILE.read_text())
        print(f"index/static: valid JSON, {len(data.get('Results', []))} result(s)")
        return

    if not args.app or not args.digest:
        parser.error("--app and --digest are required")

    repo = args.repo or f"castrojo/jorgehub/{args.app}"
    index = load_index()
    inspect_data = inspect_image(args.registry, repo, args.digest, args.tls_verify)
    index = update_index(index, args.app, repo, args.digest, inspect_data, args.tags)

    INDEX_FILE.parent.mkdir(parents=True, exist_ok=True)
    INDEX_FILE.write_text(json.dumps(index, indent=2) + "\n")
    print(f"Updated index/static: {len(index['Results'])} result(s)")


if __name__ == "__main__":
    main()
