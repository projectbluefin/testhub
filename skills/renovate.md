# Renovate

Renovate manages dependency pins in this repo via the self-hosted runner at
`projectbluefin/renovate-config`, which fires every 30 minutes.

## Runner / org config

- Runner repo: `projectbluefin/renovate-config`
- Org-wide inherited config: `org-inherited-config.json` (pushed to all `projectbluefin` repos)
  - `extends: ["config:best-practices", ":semanticCommits"]`
  - Custom manager for `image-versions.yaml` docker digest pinning
- Per-repo config: `.github/renovate.json` (this repo)
- No `schedule` field — Renovate runs on the runner's 30-min cron cadence

## What Renovate tracks in this repo

| Target | Datasource | File(s) |
|---|---|---|
| `github-actions` manager | built-in | `.github/workflows/**` |
| `release.yaml` version+url+sha256 | `github-releases` | `flatpaks/**/release.yaml` |
| `manifest.yaml` x-version+url+sha256 | `github-releases` | `flatpaks/**/manifest.yaml` |
| `quay.io/jlebon/chunkah` image tag | `docker` | `Justfile`, `build.yml` |
| `yq` version | `github-releases` (mikefarah/yq) | `Justfile` |
| `oras` version | `github-releases` (oras-project/oras) | `Justfile` |

## Apps with no Renovate coverage (intentional)

- `lmstudio` — CDN URL (`installers.lmstudio.ai`), no standard datasource
- `firefox-nightly` / `thunderbird-nightly` — Mozilla rolling nightly, no version tags
- `virtualbox` — uses `x-checker-data` (flathub tooling), not regex
- `org.altlinux.Tuner` / `io.github.DenysMb.Kontainer` — git tags at non-GitHub forges

## Known limitations

### sha256 not computed for github-releases artifacts

`currentDigest`/`newDigest` in `autoReplaceStringTemplate` only works when Renovate downloads
the artifact. For the `github-releases` datasource, Renovate does **not** download to compute
sha256. Validate when Renovate first opens a goose/ghostty update PR — a post-merge manual
sha256 check or separate verification step may be needed.

### release.yaml regex requires non-adjacent version/url

`goose/release.yaml` has a comment and `arches:` line between `version:` and `url:`. The
regex uses a non-greedy skip pattern to handle this:

```
version:\s*(?<currentValue>...)
(?:(?!version:|url:)[^\n]*\n)*   ← skips comment/config lines
url:\s*...
```

If new `release.yaml` apps are added with more than ~3 intervening lines between `version:`
and `url:`, verify the match still works with a Python test.

### autoReplaceStringTemplate fragility

The multiline `matchString` spanning `x-version` through `sha256` makes reconstruction
fragile if fields are not adjacent. If `autoReplaceStringTemplate` produces wrong output:
restructure the yaml to place `x-version` immediately above the source block, or split
into a separate regex manager.

## chunkah: two pins must stay in sync

`Justfile` (`chunkah_image`) and `build.yml` (line ~426) both pin `quay.io/jlebon/chunkah`.
Renovate will open separate PRs for each file. Merge both before triggering a build.
The `check-chunkah.yml` workflow provides a weekly drift check as a backstop.

### chunkah OCI image tag scheme

`quay.io/jlebon/chunkah` tags match GitHub release tags exactly (`v0.1.0`, `v0.2.0`, `v0.3.0`).
Renovate uses `datasource: docker` against `quay.io/jlebon/chunkah` directly — no GitHub
releases lookup needed. Latest as of 2026-03-11: `v0.3.0`.

## Plan authoring note

Check existing `workflow_dispatch` inputs before adding new ones. The `app` input already
gates per-app rebuilds. Do not add a `force-rebuild` boolean if the existing `app` input
already covers the use case.
