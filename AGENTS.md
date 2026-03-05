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
flatpak-builder (inside gnome-49 container, --privileged)
  → OSTree repo (.ostree-repo/)
  → flatpak build-bundle --oci (.ghostty.oci/)
  → skopeo copy → localhost:5000 (LOCAL_ONLY) or ghcr.io (full build)
  → update-index.py → gh-pages branch index/static
```

## Key Files

- `flatpaks/<app>/manifest.yaml` — Flatpak build manifest
- `scripts/build-local.sh` — build + push script (`LOCAL_ONLY=1` for loop mode)
- `scripts/update-index.py` — regenerates `index/static` on gh-pages branch
- `Justfile` — all commands proxied through `just`

## Critical Notes

- `SOURCE_DATE_EPOCH=0` + `--override-source-date-epoch=0` are set in `build-local.sh` — required
  for deterministic OCI blob hashes; without these, every run produces a different sha256 even
  for identical content (tar timestamps differ)
- Labels (NOT annotations) carry `org.flatpak.ref` and `org.flatpak.metadata` — flatpak client
  reads Labels only; skopeo inspect verifies this after each push
- `podman image exists` guard skips gnome-49 re-pull when cached — eliminates ~2-3s per loop
- `just build` uses `podman push --compression-format=zstd:chunked`; skopeo cannot set this
  compression format, which is why the push path uses podman (not skopeo)
- `just loop` runs entirely on host — it uses podman internally, modifies build dirs and local
  registry; do NOT wrap in a second devaipod container (podman-in-podman is not configured)

## Plans Reference

> Architecture, pipeline decisions, workflow test findings:
> `~/.config/opencode/plans/jorgehub/`
