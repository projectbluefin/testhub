# jorgehub

Personal OCI Flatpak hosting repository. Builds Flatpak apps as OCI images, pushes to
ghcr.io with `zstd:chunked` compression, and serves a Flatpak remote index via GitHub Pages.

## Skills

Domain-specific knowledge lives in `skills/`. Load the relevant skill before working in
that area.

| Skill | When to load |
|---|---|
| `skills/pipeline.md` | Build pipeline, chunkah, flatpak install validation, simplicity rule |
| `skills/versioning.md` | OCI tags, `x-version`, `version`, source URL convention |
| `skills/flatpak-labels.md` | Labels vs annotations, label preservation across chunkah |
| `skills/gh-pages-index.md` | `update-index`, worktree hygiene |
| `skills/app-gotchas.md` | Per-app known issues (firefox-nightly, lmstudio, goose, bundle-repack) |
| `skills/renovate.md` | Renovate limitations for manifest.yaml and release.yaml |

## Key files

- `flatpaks/<app>/manifest.yaml` — flatpak-builder path
- `flatpaks/<app>/release.yaml` — bundle-repack path
- `scripts/update-index.py` — regenerates `index/static` on gh-pages branch
- `Justfile` — all commands; use `just --list`

## Apps

`ghostty` (manifest.yaml), `goose` `lmstudio` `firefox-nightly` (release.yaml or manifest.yaml)

## Workflow improvement

When a CI pattern fails unexpectedly, a pipeline behavior is discovered that isn't
documented, or any step takes >2 tries to get right: update the relevant skill file
immediately. Skills are the single source of truth for this repo's institutional knowledge.

## Architecture reference

Pipeline decisions and findings are in the workflow-state DB:
`journal_search(text: "jorgehub", limit: 10)`
