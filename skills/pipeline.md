# Pipeline

Build pipeline for jorgehub. Two paths, one common output.

## Two build paths

| File | Path | Example apps |
|---|---|---|
| `flatpaks/<app>/manifest.yaml` | flatpak-builder | ghostty, firefox-nightly |
| `flatpaks/<app>/release.yaml` | bundle-repack | goose, lmstudio |

**flatpak-builder path** — builds from source inside gnome-49 container, requires offline
dependency manifests (no network during build per Flathub policy). Produces an OSTree repo
then exports OCI.

**bundle-repack path** — downloads upstream `.flatpak` bundle, verifies sha256, imports into
OSTree via `flatpak build-import-bundle`, exports OCI. Cannot inject source-side files
(e.g. `metainfo.xml`) into the bundle — see `skills/app-gotchas.md`.

## Stages (both paths)

```
flatpak-builder / bundle-repack (gnome-49 container, --privileged)
  → OSTree repo (.${app}-ostree-repo/)
  → flatpak build-bundle --oci (.${app}.oci/) — single flat layer
  → podman pull oci:... → IMAGE_ID
  → _apply-oci-labels (buildah from/config/commit/rm) → labeled IMAGE_ID
  → chunkah (--mount=type=image) → chunked OCI archive → CHUNKED_ID
  → skopeo copy → localhost:5000 (just loop) or podman push zstd:chunked → ghcr.io (just build)
  → update-index.py → gh-pages branch index/static
```

## Commands

```bash
just loop <app>      # local only: build + push to localhost:5000; no ghcr.io
just loop-all        # all apps concurrently (preferred validation pass)
just build <app>     # full: build + push to ghcr.io with zstd:chunked
just update-index <app>   # regenerate gh-pages index from latest ghcr.io digest
just check-index          # validate index/static JSON
just validate <app>       # lint manifest + metainfo inside gnome-49
```

## Determinism

`SOURCE_DATE_EPOCH=0` is required at every container invocation that touches OSTree or OCI
export. Without it, tar timestamps differ per run → different sha256 per run even for identical
content. Set it via `-e SOURCE_DATE_EPOCH=0` on every `podman run` in the build path.

`--override-source-date-epoch=0` is a flatpak-builder-only flag — do NOT pass it to
`flatpak build-bundle` (different command, different flags).

## chunkah

Pin: `quay.io/jlebon/chunkah:v0.3.0` (managed by Renovate via `CHUNKAH_SPLITTER`).

Invocation pattern (upstream-documented for Podman, image-mount method):

```bash
export CHUNKAH_CONFIG_STR
CHUNKAH_CONFIG_STR=$(podman inspect "${IMAGE_ID}" | jq -c '.[0]')
podman run --rm \
  --mount=type=image,src="${IMAGE_ID}",dest=/chunkah \
  -e CHUNKAH_CONFIG_STR \
  quay.io/jlebon/chunkah:v0.3.0 build \
  --max-layers "${MAX_LAYERS}" \
  > "/tmp/${APP}-chunked.ociarchive"
CHUNKED_ID=$(podman load < "/tmp/${APP}-chunked.ociarchive" | grep 'Loaded image:' | grep -oP '(?<=sha256:)[a-f0-9]+')
```

**Critical:** `export CHUNKAH_CONFIG_STR` BEFORE assigning it under `set -euo pipefail` —
the export must precede the assignment or bash will exit on command substitution error before
the variable is exported.

**Labels:** OCI labels must be applied BEFORE chunkah. Labels added after
`CHUNKAH_CONFIG_STR` is captured are lost. Apply via `just _apply-oci-labels` first.

`--max-layers` defaults to `16` in this repo (configurable per-app via
`chunkah-max-layers` in `release.yaml` or `x-chunkah-max-layers` in `manifest.yaml`).
Upstream default is 64; we cap lower for Flatpak use (fewer is fine, more = better dedup).

**Before modifying any chunkah invocation:** fetch upstream README and verify the pattern
matches the pinned version. Do not rely on memory of prior usage patterns.

## Push path

- `just loop` → `skopeo copy --dest-tls-verify=false` → `localhost:5000`
- `just build` → `podman push --compression-format=zstd:chunked` → `ghcr.io`
  skopeo cannot set `zstd:chunked` compression format — podman must be used for ghcr.io push.

## Host-only constraint

`just loop` / `just build` invoke nested podman directly on the host. Never wrap them in a
container. Run from the repo root on the host.

## Flatpak install validation

CI passing is not sufficient — two flatpaks were 404 on client PCs due to wrong OCI labels
even when CI passed. After any push, validate inside a throwaway container:

```bash
podman run --rm -it --privileged \
  -v ~/src/jorgehub:/workspace:z -w /workspace \
  ghcr.io/flathub-infra/flatpak-github-actions:gnome-49 bash
# inside:
flatpak remote-add --user --if-not-exists jorgehub /workspace/jorgehub.flatpakrepo
flatpak install --user --noninteractive jorgehub <app-id>
flatpak info --user <app-id>   # confirm Alt-id: sha256:... matches pushed digest
```

Loop is not complete until `flatpak install` succeeds and digest matches.

ALL flatpak operations (install, inspect, bundle extraction, `find` in
`~/.local/share/flatpak`) must run inside such a container — never on the host.

## New app CI requirement

When adding a new app (new `flatpaks/<app>/` directory), the task is NOT complete
until CI passes end-to-end:

1. Push the branch to origin
2. Trigger a manual CI run: `gh workflow run build.yml -f app=<app>`
   (or push to main if the workflow triggers on push)
3. Wait for CI to pass — check with `gh run watch`
4. Only after CI passes and the image is pushed to ghcr.io, close the GitHub issue

Never close a "new app" issue based solely on files being committed. The Flatpak
must be buildable and installable before the issue is closed.

## Simplicity rule

Tools available in gnome-49 and ubuntu-24.04 runners: `yq`, `jq`, `python3`, `curl`,
`skopeo`, `podman`, `buildah`, `flatpak`, `ostree`.

- YAML field extraction → `yq '.field' file`
- JSON processing → `jq`
- File download + verify → `curl` + `sha256sum`

Before adding any new tool, dependency, or abstraction layer: stop and ask. Default: don't add it.
