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
  → chunkah (quay.io/jlebon/chunkah:v0.2.0, --mount=type=image) → CHUNKED_ID (N content-based layers)
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
- `just loop` runs entirely on host — it uses podman internally, modifies build dirs and local
  registry; do NOT wrap in a second devaipod container (podman-in-podman is not configured)
- chunkah pin: `quay.io/jlebon/chunkah:v0.2.0` (pre-production — update when stable release ships)
- chunkah layer count for goose (~200MB): ~30 layers from OSTree object store heuristics alone;
  xattr-based component hints deferred until repo has 3+ packages (see journal 20260306-184501-301)

## Plans Reference

> Architecture, pipeline decisions, workflow test findings:
> `~/.config/opencode/plans/jorgehub/`
