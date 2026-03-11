# jorgehub

Personal OCI Flatpak hosting repository. Builds Flatpak apps as OCI images, pushes to
ghcr.io with `zstd:chunked` compression, and serves a Flatpak remote index via GitHub Pages.
Ghostty is the first app and the proof-of-concept for the full pipeline.

## Prerequisites

- `podman` — container runtime; build runs flatpak-builder inside the `gnome-49` image
- `skopeo` — OCI image copy and inspect
- Local registry must be running before `just loop`:
  ```bash
  podman run -d --name jorgehub-registry -p 5000:5000 \
    -v jorgehub-registry-data:/var/lib/registry:z \
    docker.io/library/registry:2
  ```
- `gh auth login` required for `just build` (ghcr.io push); NOT needed for `just loop`

## Build Commands

```bash
just loop ghostty          # LOCAL_ONLY: build + local registry (no ghcr push) — dev loop target
just build ghostty         # Full build + push to ghcr.io with zstd:chunked
just update-index ghostty  # Regenerate gh-pages index from latest ghcr.io digest
just check-index           # Validate index/static JSON is well-formed
```

## Pipeline

```
flatpak-builder / bundle-repack (inside gnome-49 container, --privileged)
  → OSTree repo (.ostree-repo/)
  → flatpak build-bundle --oci (.<app>.oci/) — single flat layer
  → podman pull oci:... → IMAGE_ID (loads into podman store)
  → chunkah (coreos/chunkah via Containerfile.splitter, --mount=type=image) → CHUNKED_ID (N content-based layers)
  → skopeo copy → localhost:5000 (loop) or podman push zstd:chunked → ghcr.io (build/CI)
  → update-index.py → gh-pages branch index/static
```

Two build paths under `flatpaks/<app>/`:
- `manifest.yaml` — flatpak-builder (e.g. ghostty)
- `release.yaml` — bundle-repack: download upstream `.flatpak`, verify sha256, import, export OCI (e.g. goose)

## Key Files

- `flatpaks/<app>/manifest.yaml` — Flatpak build manifest (flatpak-builder path)
- `flatpaks/<app>/release.yaml` — upstream bundle descriptor (bundle-repack path)
- `scripts/update-index.py` — regenerates `index/static` on gh-pages branch
- `Justfile` — all commands proxied through `just`

## Versioning Convention

**Every package in this repo must carry an explicit version tag on ghcr.io in addition to `:latest`.**

| Build path | Version source | OCI tag produced |
|---|---|---|
| `release.yaml` (bundle-repack) | `version:` field in `release.yaml` | `:v1.2.3` |
| `manifest.yaml` (flatpak-builder) | `x-version:` field in `manifest.yaml` | `:1.2.3` |

Rules:
- `release.yaml` apps: `version` is a required field — CI errors if missing
- `manifest.yaml` apps: add `x-version: "<version>"` as a top-level field; flatpak-builder ignores `x-`-prefixed fields
- If `x-version` is absent, CI warns and pushes `:latest` only — this is a gap, not intentional
- Version strings must reflect the actual upstream version of the bundled app (not build dates, git shas, or repo versions)
- When upgrading an app, update `x-version` (or `version`) in the same commit that updates the source URL/sha256

## Critical Notes

- `SOURCE_DATE_EPOCH=0` is set at job level in CI — required for deterministic OCI blob hashes;
  without it, every run produces a different sha256 even for identical content (tar timestamps differ)
- Labels (NOT annotations) carry `org.flatpak.ref` and `org.flatpak.metadata` — flatpak client
  reads Labels only; skopeo inspect verifies this after each push
- Labels are preserved across chunkah via `CHUNKAH_CONFIG_STR=$(podman inspect "${IMAGE_ID}" | jq -c '.[0]')`;
  must `export CHUNKAH_CONFIG_STR` before assigning under `set -euo pipefail`
- `podman image exists` guard skips gnome-49 re-pull when cached — eliminates ~2-3s per loop
- `just build` uses `podman push --compression-format=zstd:chunked`; skopeo cannot set this
  compression format, which is why the push path uses podman (not skopeo)
- All agent tasks and local development run via devaipod (one session per app):
  `~/.cargo/bin/devaipod run ~/src/jorgehub --host -c 'just loop <app>'`
  The devcontainer must support privileged containers (`capAdd: SYS_ADMIN`) for nested podman
  in `just loop` / `just build` to work. Verify `devcontainer.json` before first run.
- chunkah pin: `coreos/chunkah` v0.2.0 — fetched as `Containerfile.splitter` from GitHub releases (not a container image); see `CHUNKAH_SPLITTER` env var in build.yml/backfill.yml; pin is managed by Renovate
- chunkah layer count for goose (~200MB): ~30 layers from OSTree object store heuristics alone;
  xattr-based component hints deferred until repo has 3+ packages (see journal 20260306-184501-301)
- **Flatpak install validation is mandatory after any OCI push (loop or build).** CI green is not
  sufficient — two flatpaks were 404 on client PCs due to wrong OCI labels/index even when CI
  passed. After `just loop <app>` or `just build <app>`, run inside a devaipod container:
  ```bash
  flatpak remote-add --user --if-not-exists jorgehub ~/src/jorgehub/jorgehub.flatpakrepo
  flatpak install --user --noninteractive jorgehub <app-id>
  flatpak info --user <app-id>   # confirm Alt-id: sha256:... matches pushed digest
  ```
  The loop is not complete until `flatpak install` succeeds and `flatpak info` shows the correct digest.
- **Source URL convention for manifest.yaml apps:** Always use immutable versioned tag archive URLs
  (e.g. `https://github.com/ghostty-org/ghostty/archive/refs/tags/v1.3.0.tar.gz`). Never use
  rolling `tip`, `latest`, or branch archive URLs — the tarball content and sha256 change without
  notice, causing non-deterministic build failures. When upgrading, find the exact tag URL and
  update sha256 in the same commit.
- **gh-pages worktree: always fetch before committing.** Before any `git add` in the gh-pages
  worktree, run `git fetch origin gh-pages && git rebase origin/gh-pages`. Committing after a
  stash-pop onto a diverged remote and then rebasing causes git to treat JSON content as plain
  text and merge both versions — the result is duplicate entries in `index/static` JSON files.
  Always manually verify dedup after any rebase of index/static changes. **Session hygiene:**
  session-end must commit or discard any pending gh-pages worktree changes — never leave the
  worktree in a dirty or detached HEAD state between sessions.

## Simplicity Rule

**Prefer tools that are already available in the build environment over custom code.**

The gnome-49 container and ubuntu-24.04 runners include `yq`, `jq`, `python3`, `curl`,
`skopeo`, `podman`, `buildah`, `flatpak`, `ostree`. Use these directly.

**Before adding any inline script, helper function, or new dependency, ask:**
> "Does a pre-installed tool already do this?"

Specifically:
- YAML field extraction → `yq '.field' file` (NOT inline python3/awk/sed)
- JSON processing → `jq` (NOT inline python3)
- File download + verify → `curl` + `sha256sum` (NOT custom scripts)

**When making a change that adds new tooling, a new dependency, or a new abstraction layer,
stop and ask the user first.** This repo is intentionally minimal. The right default is
"don't add it" unless there's no alternative.

## Architecture Reference

> Architecture, pipeline decisions, and workflow test findings are stored in the
> workflow-state DB. Search with: `journal_search(text: "jorgehub", limit: 10)`

## Renovate Limitations

- **manifest.yaml autoReplaceStringTemplate fragility:** The multiline Renovate `matchString`
  spanning `x-version` through `sha256` makes faithful reconstruction fragile when fields are
  not adjacent. If autoReplaceStringTemplate produces wrong output, restructure `manifest.yaml`
  to place `x-version` immediately above the source block, or handle `x-version` in a separate
  regex manager.
- **Renovate cannot compute sha256 for github-releases artifacts:** `currentDigest`/`newDigest`
  in `autoReplaceStringTemplate` only works when Renovate downloads the artifact. For
  `github-releases` datasource it does NOT download to compute sha256. Validate when Renovate
  first runs on a goose update — a post-Renovate hook or manual update may be required.

## Plan Authoring Notes

- **Check existing workflow_dispatch inputs before adding new ones.** `workflow_dispatch` inputs
  like `app` already gate per-app rebuilds. Do not write a plan task that adds a `force-rebuild`
  boolean if the existing `app` input already covers the use case.
