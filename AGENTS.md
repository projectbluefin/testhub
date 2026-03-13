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

`ghostty` `thunderbird-nightly` `virtualbox` (manifest.yaml), `goose` `lmstudio` `firefox-nightly` (release.yaml or manifest.yaml)

## Test builds

When triggering a manual test build, always use `goose` (bundle-repack, fastest — no compile step).
Never use `ghostty` for test builds (full Zig compile via flatpak-builder, very slow).

## CI validation gate

**A goose-only green run is not sufficient to declare any CI change complete.**

goose is a `release.yaml` app with a `url` field. It exercises a different code path than
`manifest.yaml` apps and apps without a `url` field (ghostty, thunderbird-nightly, virtualbox).

**Before merging any change to `build.yml`, `Justfile`, or `update-index.yml`:**

- Smoke test (fast): `goose` — catches most regressions quickly
- Full gate: must also pass for at least one `manifest.yaml` app with no `url` field

Use `thunderbird-nightly` as the second app (x86_64-only, no Zig compile, faster than ghostty).
If the change is CI-wide (affects all apps/jobs), trigger **both** before declaring complete.

## Flatpak installation policy

Always install Flatpaks user-wide. Always use `--user`.

```bash
# Correct
flatpak install --user <remote> <app-id>

# Wrong — never install system-wide
flatpak install <remote> <app-id>
```

This applies to all install operations: manual testing, validation steps, CI validation containers, and any instructions written in skills or documentation. If an upstream doc omits `--user`, add it.

## Skill usage — mandatory

**Load the relevant skill before touching any file in its domain.** This is not optional.

| You are about to... | Load skill |
|---|---|
| Change `build.yml`, `update-index.yml`, Justfile, or chunkah flags | `skills/pipeline.md` |
| Change `x-version`, `version`, source URL, or OCI tag logic | `skills/versioning.md` |
| Add or change OCI labels, annotations, or chunkah label output | `skills/flatpak-labels.md` |
| Run or debug `update-index`, gh-pages worktree, or index shape | `skills/gh-pages-index.md` |
| Add a new app, change finish-args, hit a build quirk | `skills/app-gotchas.md` |
| Touch Renovate config or understand why a dep isn't auto-updated | `skills/renovate.md` |

## Skill improvement — mandatory

Skills are the single source of truth for this repo's institutional knowledge.
**Any of these events requires an immediate skill update before moving on:**

- A CI step fails unexpectedly and the root cause is not already documented
- A pipeline behavior is discovered that isn't in the relevant skill
- Any fix takes more than one attempt to get right
- A lint error, build error, or tool quirk is found that could recur

**How to update:** edit the relevant `skills/*.md` file, commit with `docs(skills): ...`,
then record the finding in the workflow-state journal:
`journal_write(title: "...", body: "...", tags: "ci-cd")`

## Architecture reference

Pipeline decisions and findings are in the workflow-state DB:
`journal_search(text: "jorgehub", limit: 10)`
