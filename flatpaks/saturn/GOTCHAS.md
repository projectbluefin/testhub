# Saturn — Known Issues and Build Notes

## ECL compile time (slow first build)

Saturn builds ECL (Embeddable Common Lisp) from source as a Flatpak module. ECL is a
full Common Lisp implementation compiled from C — the first build takes 20–40 minutes.

Subsequent CI runs use the `actions/cache` ccache provided by the
`flatpak/flatpak-github-actions/flatpak-builder` action, so rebuild time drops to ~1 min.

**Do not use Saturn as a test app for quick CI iteration — use `goose` instead.**

## No upstream tags / Renovate cannot auto-track

Saturn has no GitHub releases or tags. The manifest pins to a specific git commit.
When Saturn's upstream advances, the commit hash in `manifest.yaml` (both the `saturn`
module source and the 15 CL deps) must be bumped manually.

Renovate cannot auto-track commit-only sources without a release tag.

## app-id key: use `app-id:` not `id:`

flatpak-builder accepts both `id:` and `app-id:` in YAML manifests, but testhub's
Justfile `metadata` recipe reads `app-id` explicitly via `yq e ".app-id // \"\""`.
Using `id:` causes the OCI export step to fail with:

```
ERROR: could not determine app-id
```

All testhub manifests must use `app-id:`. This is already correct in Saturn's manifest
but document it here to prevent future regression.

## Three lint stages — three screenshot exception keys

testhub runs `flatpak-builder-lint` at three stages, each with distinct exception namespaces:

| Lint stage | Command | Screenshot exception key |
|---|---|---|
| manifest | `flatpak-builder-lint manifest manifest.yaml` | `metainfo-missing-screenshots` |
| builddir | `flatpak-builder-lint builddir flatpak_app` | `appstream-missing-screenshots` |
| repo | `flatpak-builder-lint repo repo` | `appstream-screenshots-not-mirrored-in-ostree` |

Saturn has no screenshots. All three keys are in `exceptions.json`. If screenshots are
added in future, all three exceptions can be removed — but ensure screenshots are
reachable URLs (appstreamcli live-fetches them).

## Broad filesystem permissions (Flatpak manager)

Saturn requires:
- `--filesystem=/var/lib/flatpak` — system-wide Flatpak installs → `finish-args-flatpak-system-folder-access`
- `--filesystem=home` — `~/.local/share/flatpak` user installs → `finish-args-home-filesystem-access`
- `--talk-name=org.freedesktop.Flatpak` — Flatpak system daemon IPC → `finish-args-flatpak-spawn-access`

These are justified for a Flatpak manager. All three are covered by exceptions in
`exceptions.json`.

## x-skip-launch-check required (GTK4 GUI)

Saturn is a GTK4 GUI app. The e2e-install CI launch check (`timeout 5 flatpak run`) exits 1
with "Failed to open display" in the headless gnome-50 container (no Wayland/X11).

`x-skip-launch-check: true` must remain in `manifest.yaml` to prevent the launch check
from failing. The install step still validates that the Flatpak installs correctly.

## Bootstrap: two-build pattern for new apps

On first CI build, Saturn was not yet in the testhub index, so the e2e-install step would
fail with "Nothing matches app-id in remote 'testhub'".

**Solution used:** `x-skip-install-test: true` in manifest for Build 1 (bootstrap).
- Build 1 runs with this flag → app is built, pushed, indexed; install test skipped
- Build 2 runs without this flag → real `flatpak install --user testhub io.github.kolunmi.Saturn`

The bootstrap flag has been **removed** from `manifest.yaml` after Build 5 succeeded.
Saturn is now in the testhub index; future rebuilds will do the full e2e install test.

## CL dependency pinning

The 15 Common Lisp library dependencies in the `saturn-cl-deps` module use pinned commits
for reproducibility. Several repos (from kolunmi's GitHub) have no semantic version tags.

When bumping CL deps, update both the `commit:` hash and (where present) the `tag:` field.

## Full exceptions.json reference

```json
{
    "io.github.kolunmi.Saturn": [
        "appid-filename-mismatch",
        "appstream-no-flathub-manifest-key",
        "metainfo-missing-screenshots",
        "appstream-missing-screenshots",
        "appstream-screenshots-not-mirrored-in-ostree",
        "finish-args-home-filesystem-access",
        "finish-args-flatpak-spawn-access",
        "finish-args-flatpak-system-folder-access"
    ]
}
```
