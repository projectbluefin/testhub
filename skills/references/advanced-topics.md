# Advanced Topics (Pipeline)

Reference material extracted from `skills/pipeline.md`. Load when working on the specific
topic; otherwise `skills/pipeline.md` covers day-to-day needs.

## devcontainers/ci for compile-oci (future work)

The `compile-oci` job currently uses a bare `container:` stanza with the gnome-49 image.
The goal is to switch it to `devcontainers/ci@v0.3` so `.devcontainer/devcontainer.json`
becomes the single source of truth for the build environment (same container for local dev
and CI), per https://containers.dev upstream best practice.

**Why not done yet:** `flatpak/flatpak-github-actions/flatpak-builder@v6` is a composite
GitHub Action that internally uses `actions/cache` — it cannot be called from inside
`devcontainers/ci`'s `runCmd`. Migration requires replacing it with direct
`flatpak-builder` commands + manual ccache wiring in a Justfile recipe, which is a
non-trivial restructuring. Deferred to avoid blocking active work.

**Migration path when ready:**
1. Create `just compile-oci <app> <arch>` recipe consolidating all build logic
2. Handle ccache via `actions/cache` restore/save steps outside devcontainers/ci
3. Replace `container:` stanza + inline steps with `devcontainers/ci@v0.3` step calling the recipe
4. Keep checkout, artifact upload, and issue-filing as bare runner steps

## Staging tags — do NOT delete

Staging tags (`sha-<sha>-<arch>`) are intentionally permanent. ghcr.io permanently
deletes manifest blobs when a version/tag is deleted. Since `skopeo copy` within the
same registry creates only a tag alias (not an independent copy), deleting the staging
tag version destroys the content manifest that the OCI image index references by digest,
breaking `flatpak install` with "manifest unknown". Staging tags accumulate and are
cleaned up manually via `cleanup.yml` when needed. Never add cleanup of staging tags
to the main build pipeline.
