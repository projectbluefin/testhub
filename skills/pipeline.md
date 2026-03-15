# Pipeline

Build pipeline. Two paths, one common output.

## When to Use
- Changing `build.yml`, Justfile, or chunkah flags
- Debugging lint failures, build errors, or install issues

## When NOT to Use
- App-specific quirks → `skills/app-gotchas.md`
- OCI label questions → `skills/flatpak-labels.md`
- Index / gh-pages changes → `skills/gh-pages-index.md`

## Two build paths

| File | Path | Example apps |
|---|---|---|
| `flatpaks/<app>/manifest.yaml` | flatpak-builder | ghostty, firefox-nightly, lmstudio |
| `flatpaks/<app>/release.yaml` | bundle-repack | goose |

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

### x-skip-chunkah

chunkah requires at least one "component repo" to be detected in the rootfs: an rpmdb,
files >= 1MB (bigfiles), or `user.component` xattrs. Small apps built via `flatpak-builder`
(e.g. a tiny KDE/Qt widget like Kontainer, ~750 KiB) have none of these — no rpmdb,
no large files, and no xattrs. chunkah exits with "no supported component repo found in rootfs".

Attempting to inject xattrs via `setfattr` in a `RUN --mount` inside a custom Containerfile
(the "xattr injection" approach) does NOT work: the xattr is set on the mount-point directory
in the chunkah container's namespace, not on a file inside the mounted rootfs overlay, so
chunkah's scanner never sees it.

**Fix:** Add `x-skip-chunkah: true` to the app's `manifest.yaml`. The pipeline detects this
flag and sets `CHUNKED="${LABELED}"`, skipping chunkah entirely. The image is pushed as a
single layer, which is fine — the app is too small to benefit from layer deduplication.

**Rule:** Any manifest.yaml app that is a small GUI widget or utility (< ~5MB total,
no system dependencies beyond the SDK) should use `x-skip-chunkah: true`.

```yaml
# flatpaks/<app>/manifest.yaml
x-skip-chunkah: true
```

Note: `x-skip-chunkah` is only supported for `manifest.yaml` apps (flatpak-builder path).
Bundle-repack (`release.yaml`) apps typically have large upstream bundles and do not
need this flag.

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
  -v ~/src/<repo>:/workspace:z -w /workspace \
  ghcr.io/flathub-infra/flatpak-github-actions:gnome-49 bash
# inside:
flatpak remote-add --user --if-not-exists <repo> /workspace/<repo>.flatpakrepo
flatpak install --user --noninteractive <repo> <app-id>
flatpak info --user <app-id>   # confirm Alt-id: sha256:... matches pushed digest
```

Loop is not complete until `flatpak install` succeeds and digest matches.

**Note:** `flatpak remote-ls` may not show a newly published app immediately — wait for "Sync Flatpak Remote Index" to complete (runs after build, takes a few minutes).

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

## Runtime-update PRs

When a runtime-update PR is created (e.g. by raptor[bot] or Copilot), the manifest
may already reflect the target state — `runtime-version` set on import with no other
diffs. **CI will not trigger on a branch with no file changes to `flatpaks/`.**

To trigger CI: make a real, correct change to the manifest. The canonical fix is to
set `x-version` to the current upstream release version (check Flathub or the upstream
repo). This is always a valid improvement — `x-version` must not be empty.

## flatpak-builder-lint known errors

`build.yml` runs `flatpak-builder-lint manifest "flatpaks/$app/manifest.yaml"` during CI.
The linter has several known behaviors that affect this repo:

### appid-filename-mismatch (hard blocker)

The linter expects the manifest filename to match the app-id, e.g. `org.example.App.yaml`.
Every app in this repo uses `manifest.yaml` — this triggers `appid-filename-mismatch` on every
manifest.yaml-based app.

**Fix applied:** Each manifest.yaml-based app has a `flatpaks/<app>/exceptions.json`:
```json
{
    "<app-id>": ["appid-filename-mismatch"]
}
```

`build.yml` passes `--exceptions --user-exceptions <file>` when the file exists. This is
the active approach — do not rename manifests to `<app-id>.yaml`.

When adding a new manifest.yaml-based app, create `flatpaks/<app>/exceptions.json` with the
app's actual app-id suppressing `appid-filename-mismatch`.

### manifest-unknown-properties (cleanup-commands at module scope)

`cleanup-commands` is not in the flatpak-builder JSON schema at module scope — using it
causes `jsonschema-validation-error`. The correct fields at module scope are:
- `cleanup` — list of file glob patterns to remove after build (NOT shell commands)
- `build-commands` or `post-install` — for shell commands that run during/after the build

Extension stub directories (e.g. `mkdir -p $FLATPAK_DEST/lib/ffmpeg`) must go in
`build-commands` or `post-install`, not `cleanup`.

### finish-args-unnecessary-xdg-config-gtk-3.0-ro-access (error, not warning)

`--filesystem=xdg-config/gtk-3.0:ro` in `finish-args` is flagged as a hard error (the
linter considers it unnecessary). Remove the permission or add it to `exceptions.json`.

### Icon sha256 values in manifests

When pinning per-size icons from hg-edge.mozilla.org, verify each sha256 independently:
```bash
curl -sL "<url>" | sha256sum
```
Do not copy-paste sha256 values across icon sizes — the values are not interchangeable and
a swap causes a silent build failure (download succeeds but verification fails).

### builddir and repo lint (post-build, flatpak-builder path only)

`build.yml` runs two additional lint modes after `flatpak-builder` completes, before OCI export.
These only apply to manifest.yaml apps (ghostty, firefox-nightly, lmstudio). Bundle-repack apps (goose) do not produce a flatpak-builder staging directory or OSTree repo, so these modes
cannot run on them.

**`flatpak-builder-lint builddir flatpak_app`** — checks the staging build directory. Key
checks: appstream catalog present, desktop file valid, icon installed, ELF arch matches.
Path `flatpak_app` is the default `build-dir` from flatpak/flatpak-github-actions v6.

**`flatpak-builder-lint repo repo`** — checks the exported OSTree repository. Key checks:
OSTree ref shape, appstream catalog in OSTree, screenshot mirroring. Path `repo` is the
default `repo-dir` from flatpak/flatpak-github-actions v6. This is the same check Flathub
runs on all production builds.

**Three distinct stages:** lint fires at manifest (pre-build), builddir (post-build staging), and repo (post-OSTree export). An exception needed at builddir is NOT automatically applied at repo stage — always verify `exceptions.json` covers all three stages before declaring a lint failure fixed.

All three steps use the same `exceptions.json` file.

#### Required exceptions for non-Flathub repos

These errors can fire on manifest.yaml apps in testhub. Which ones apply depends on the
app's metainfo content:

| Exception | When it fires | Add? |
|---|---|---|
| `appstream-no-flathub-manifest-key` | Always — `flathub::manifest` custom tag only required for Flathub submissions | Always |
| `appstream-screenshots-not-mirrored-in-ostree` | App has screenshots in metainfo but `--mirror-screenshots-url` not passed | If app has screenshots |
| `appstream-external-screenshot-url` | App has screenshots pointing to external URLs (not dl.flathub.org/media) | If app has screenshots |
| `metainfo-missing-screenshots` | App has no screenshots in metainfo | If app has no screenshots |
| `elf-arch-multiple-found` | App bundles multiple ELF architectures (Electron apps do this) | Electron apps |

**Practical rule:** Add `appstream-no-flathub-manifest-key` universally. Then:
- If the app **has** screenshots in metainfo: add `appstream-external-screenshot-url` + `appstream-screenshots-not-mirrored-in-ostree`
- If the app **has no** screenshots: add `metainfo-missing-screenshots`

Note: `appstream-screenshots-not-mirrored-in-ostree` and `appstream-external-screenshot-url`
fire at **different** lint stages (builddir vs repo respectively) — both must be in
`exceptions.json` or the build will fail at one stage even if the other passes.

**`metainfo.xml` appstream validation:** `metainfo.xml` must contain both
`<launchable type="desktop-id">` and `<developer id="...">` tags or appstream validation
fails with `appstream-failed-validation`. Missing either triggers the error.

If CI surfaces additional errors after first run, add them to `exceptions.json` and
document in the app's `GOTCHAS.md`. Do not add metainfo fields we cannot keep accurate
(developer name, screenshots, VCS URLs) — suppress via exceptions instead.

Per-app additional exceptions are documented in each app's `GOTCHAS.md`.

#### Running locally

```bash
# After a local build that produced flatpak_app/ and repo/:
flatpak-builder-lint --exceptions --user-exceptions flatpaks/<app>/exceptions.json builddir flatpak_app
flatpak-builder-lint --exceptions --user-exceptions flatpaks/<app>/exceptions.json repo repo
```

## Fixing agent PR contract

When a runtime-update or build-failure issue is filed, the fixing agent works as follows:

### Branch naming

One branch per app, always:
```
raptor/runtime-<app-id>
```

Example: `raptor/runtime-io.github.DenysMb.Kontainer`

### One PR per app

- If no PR exists for the branch, create one: `raptor/runtime-<app-id>` → `main`
- If a PR already exists (check with `gh pr list --head raptor/runtime-<app-id>`), push fix commits directly to the existing branch — do NOT open a new PR
- Build failure fix iterations always go on the same branch/PR

### Where to find context

The **runtime-update issue** for an app is the source of truth for what needs to change. Its title is always `runtime-update: <app-id>`.

The **build-failure issue** body contains:
- The target branch name (explicit)
- A link to the runtime-update issue (if one exists)
- Instructions: push to the existing branch, not a new PR

### What goes on the branch

All of these must be committed to the same `raptor/runtime-<app-id>` branch:
- Manifest fix (the primary change)
- `skills/app-gotchas.md` update (if the fix reveals an app-specific quirk)
- Any other `skills/` update (if the fix reveals a pipeline gap)
- `flatpaks/<app>/exceptions.json` update (if new lint exceptions are needed)

### Closing issues

- Close the **build-failure issue** once the fix is merged and CI passes
- Close the **runtime-update issue** once the runtime version is current and the build passes

## Container image provenance

Build and install-test jobs use `ghcr.io/flathub-infra/flatpak-github-actions:gnome-49`.

**Important:** `flathub-infra/flatpak-github-actions` was **archived** (deprecated April 24, 2025).
Images are now served from `flathub-infra/actions-images` but the `ghcr.io` image path and
tags remain stable. The `gnome-49` tag continues to work. Renovate does not manage this tag —
update manually when a newer GNOME SDK version is required.

## Simplicity rule

Tools available in gnome-49 and ubuntu-24.04 runners: `yq`, `jq`, `python3`, `curl`,
`skopeo`, `podman`, `buildah`, `flatpak`, `ostree`.

- YAML field extraction → `yq '.field' file`
- JSON processing → `jq`
- File download + verify → `curl` + `sha256sum`

Before adding any new tool, dependency, or abstraction layer: stop and ask. Default: don't add it.

## cosign verify and merge queue

`cosign verify --certificate-identity=<url>@${{ github.ref }}` fails in the merge queue
because `github.ref` is `refs/heads/gh-readonly-queue/main/pr-N-...`, not `refs/heads/main`.
The signing cert records the actual runtime ref, so the expected identity doesn't match.

**Fix:** Use `--certificate-identity-regexp` with a prefix match:

```yaml
cosign verify \
  --certificate-identity-regexp='^https://github\.com/<org>/<repo>/\.github/workflows/build\.yml@refs/heads/' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ...
```

Apply the same regexp to `cosign verify-attestation`. Never use `--certificate-identity`
with a literal `@${{ github.ref }}` in any workflow that runs on `merge_group` events.

## CI environment differences

Two distinct runner environments are used. Assuming tool availability in the wrong context is a common source of CI failures.

| Job | Runner | Container |
|---|---|---|
| `compile-oci`, `e2e-install` | ubuntu-24.04 | **gnome-49** (flatpak-builder, ostree, buildah, yq after install, python3) |
| `sign-and-push`, `publish-manifest-list`, `annotate-packages` | ubuntu-24.04 | **bare** (no container; podman+buildah via Homebrew, cosign via action, oras via download, skopeo, gh) |

### `just` availability

- gnome-49 container jobs: `just` must be installed explicitly before the first `just` call (add an "Install just" step)
- bare ubuntu-24.04 jobs: same — `just` is not pre-installed on any runner; always add the install step

### `brew` PATH on ubuntu-24.04

`brew` is at `/home/linuxbrew/.linuxbrew/bin/brew` on ubuntu-24.04 runners and is **not on PATH** inside `just` subshells. Reference it by full path or add to PATH explicitly:

```bash
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
brew install ...
```

### oras version requirement

`oras manifest index create` was added in **oras v1.3.0**. Pinning to v1.2.x or earlier will fail with "unknown command". Always use oras >= v1.3.0 for manifest index operations.

## Bash safety in GitHub Actions `run:` blocks

Under `bash -e` (the default for Actions `run:` blocks), a conditional that evaluates false **as the last command** exits the step with code 1.

**Danger pattern:**
```bash
[[ -n "${URL}" ]] && echo "UPSTREAM_URL=${URL}" >> "$GITHUB_ENV"
```
When `URL` is empty, `[[ -n "" ]]` is false and the `&&` short-circuits. The step exits 1.

**Fix:** always append `|| true` or use an `if` block:
```bash
[[ -n "${URL}" ]] && echo "UPSTREAM_URL=${URL}" >> "$GITHUB_ENV" || true
# or
if [[ -n "${URL}" ]]; then echo "UPSTREAM_URL=${URL}" >> "$GITHUB_ENV"; fi
```

This applies to any bare `[[` condition, `&&`-chain, or command that may legitimately fail as the final line of a `run:` block.

**`run:` blocks — heredocs:** `<<'EOF'` heredocs inside YAML `run: |` blocks cause YAML parse errors — the terminator at column 0 is interpreted as a YAML key. Use `printf '%s\n' '...' > /tmp/file` instead.

## `just` recipe Bash patterns

### Heredoc syntax

`<<'EOF'` heredocs in `just` recipes cause parser errors. Use `printf` instead:

```bash
# Wrong — causes just parse error
cat <<'EOF'
...
EOF

# Correct
printf '%s\n' '...'
```

### Bracket syntax in non-shebang recipes

`[ -f ... ]` can be misinterpreted by the just parser in non-shebang recipes. Use `test -f` form, or switch to a shebang recipe (`#!/usr/bin/env bash`).

### `$$` expansion

`@`-prefix just recipes do NOT expand `$$` to `$` — only shebang-style recipes handle this correctly. Use shebang-style recipes (`#!/usr/bin/env bash`) for any recipe that uses `$$` or complex bash syntax.

## yq null-coalescing syntax

yq uses `// ""` (empty string literal) as the null-coalescing operator, NOT `// empty` (which is jq syntax and fails with yq):

```bash
# Wrong — jq syntax, fails with yq
yq '.key // empty' file.yaml

# Correct
yq '.key // ""' file.yaml
```

## Upstream documentation — always check first

Before making any change to the pipeline, CI, or tooling, check the upstream documentation
for the relevant tool. This is mandatory. Do not rely on memory or prior usage patterns.

Key upstream docs to check by area:

| Area | Upstream doc |
|---|---|
| devcontainers/ci action | https://github.com/devcontainers/ci/blob/main/docs/github-action.md |
| containers.dev spec | https://containers.dev/implementors/reference/ |
| flatpak-builder | https://docs.flatpak.org/en/latest/flatpak-builder-command-reference.html |
| flatpak/flatpak-github-actions | https://github.com/flatpak/flatpak-github-actions |
| chunkah | https://github.com/jlebon/chunkah |
| cosign | https://docs.sigstore.dev/cosign/signing/overview/ |
| oras | https://oras.land/docs/ |

## devcontainers/ci for compile-oci (future work)

Deferred — see [`skills/references/advanced-topics.md`](references/advanced-topics.md#devcontainersci-for-compile-oci-future-work).

## GitHub Actions efficiency — stage your pushes

Each push to `main` triggers `build.yml` for **all apps** (the `all apps` matrix strategy).
Each manually dispatched `gh workflow run build.yml -f app=<x>` uses additional runner slots.
Simultaneous pushes create concurrent runs that fight for the same runners and waste minutes.

**Rules for agents and humans:**

1. **Check before pushing.** Always run `gh run list --repo projectbluefin/testhub --workflow=build.yml --json status --jq '[.[]|select(.status=="in_progress")]|length'` before pushing. If any run is in_progress, batch your changes and wait, or push once at the end.

2. **Batch all changes into one push.** When fixing multiple apps in one session, stage all commits locally (`git commit` each) then push once (`git push`). One push = one CI run.

3. **Do not manually trigger builds after a push.** A push to `main` already triggers `build.yml` for all apps. Manually running `gh workflow run build.yml` on top of a push doubles the runner usage. Only manually dispatch if your change did NOT trigger a build (e.g., docs-only commits, or you need to test a specific app that a previous push didn't cover).

4. **Do not push from multiple parallel agents simultaneously.** When multiple background agents are each committing and pushing independently, they create separate CI runs per push. Instead, have agents commit locally and coordinate a single push, or accept that they will create separate runs and ensure agents check for conflicts before pushing.

5. **For automated bot workflows** (like `update-mozilla-nightly.yml`): always push to a branch and open a PR rather than trying to push directly to `main`. The merge queue serializes changes and prevents concurrent main-branch build storms. **Note:** PRs opened by `GITHUB_TOKEN` do NOT trigger `pull_request` CI events (GitHub security policy) — use a PAT stored as a secret (`NIGHTLY_UPDATE_TOKEN`) for bot PRs that need CI, or manually dispatch the workflow on the PR branch.

6. **Concurrency group awareness.** `build.yml` has a `concurrency` group per app — a new push for the same app cancels an in-progress run. This is intentional for feature branches but undesirable for `main`. Avoid pushing rapidly in succession on main.

7. **Always use `actions/cache`.** Any workflow that downloads large files, computes hashes, or repeats expensive operations should cache intermediate results. Use ETags or content hashes as cache keys so the cache is only busted when upstream actually changes. Prefer `actions/cache/restore` + `actions/cache/save` (split) over the combined `actions/cache` so you can save even on failure (`if: always()`). Example pattern used in `update-mozilla-nightly.yml`: cache ETag files with key `<prefix>-${{ github.run_id }}` and `restore-keys: <prefix>-` so each run saves fresh ETags while always restoring the most recent prior run's values.

**Quick check command:**
```bash
gh run list --repo projectbluefin/testhub --workflow=build.yml --limit 5 \
  --json displayTitle,status,conclusion,createdAt \
  --jq '.[] | "\(.status)\t\(.conclusion // "running")\t\(.displayTitle)"'
```

## Staging tags — do NOT delete

Permanent — see [`skills/references/advanced-topics.md`](references/advanced-topics.md#staging-tags--do-not-delete).
