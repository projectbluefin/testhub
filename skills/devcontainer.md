# Devcontainer

Adapted from [trailofbits/devcontainer-setup](https://skills.sh/trailofbits/skills/devcontainer-setup).

## Overview

The devcontainer uses `ghcr.io/flathub-infra/flatpak-github-actions:gnome-49` — the same
image CI uses for `compile-oci`. This gives full local/CI parity: same tools, same runtime,
same `flatpak-builder` version.

**Open in VS Code:** "Reopen in Container"  
**CLI helper:** `.devcontainer/install.sh self-install` → adds `devc` command to PATH

## Key design decisions

| Decision | Reason |
|---|---|
| Same gnome-49 image as CI | Local/CI parity; no drift |
| `SOURCE_DATE_EPOCH=0` in containerEnv | Deterministic builds match CI |
| `postCreateCommand` installs just + yq | These are not in base image; versions pinned to match CI |
| No Dockerfile | Base image is immutable infra-managed; avoid drift by not layering |
| `.flatpak-builder/` not in a volume | It lives in the workspace (bind mount) so it persists naturally |

## Persistent volumes (from Trail of Bits pattern)

Named volumes survive container rebuilds. Format:

```json
"mounts": [
  "source={{PROJECT_SLUG}}-<purpose>-${devcontainerId},target=<path>,type=volume"
]
```

Currently no extra volumes are needed — workspace bind mount covers `.flatpak-builder/`
cache and OSTree repos. Add volumes if any of these move outside the workspace.

## Local build workflow

```bash
# Build one app locally (same as CI compile-oci, no ghcr.io push)
just loop <app>

# Build all apps locally
just loop-all

# Run full build + push to ghcr.io (requires GITHUB_TOKEN with packages:write)
just build <app>
```

## Adding new tools to the devcontainer

1. If the tool has a `just install-tools-*` recipe, add it to `postCreateCommand`
2. If not, add an `apt-get install` or `curl` step — do NOT modify the base image
3. Pin versions to match CI (check `.github/workflows/build.yml`)

## `devcontainers/ci` in CI (future work)

The goal is to replace the bare `container:` stanza in `compile-oci` with
`devcontainers/ci@v0.3` so this `devcontainer.json` becomes the single source of truth.

**Blocker:** `flatpak/flatpak-github-actions/flatpak-builder@v6` is a GitHub Action that
cannot be called from inside `devcontainers/ci`'s `runCmd`. Migration requires replacing
it with direct `flatpak-builder` commands + manual ccache wiring in a Justfile recipe.

See `skills/pipeline.md` → "devcontainers/ci for compile-oci (future work)" for the
full migration plan.
