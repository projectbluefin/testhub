# Saturn — Known Issues and Build Notes

## ECL compile time (slow first build)

Saturn builds ECL (Embeddable Common Lisp) from source as a Flatpak module. ECL is a
full Common Lisp implementation compiled from C — the first build takes 20–40 minutes.

Subsequent CI runs use the `actions/cache` ccache provided by the
`flatpak/flatpak-github-actions/flatpak-builder` action, so rebuild time is much shorter.

Do not use `saturn` as a test app for quick CI iteration — use `goose` instead.

## No upstream tags / Renovate cannot auto-track

Saturn has no GitHub releases or tags. The manifest pins to a specific git commit.
When Saturn's upstream advances, the commit hash in `manifest.yaml` (both the `saturn`
module source and any CL deps) must be bumped manually.

Renovate cannot auto-track commit-only sources without a release tag.

## Broad filesystem permissions

Saturn requires:
- `--filesystem=/var/lib/flatpak` — to read and manage system-wide Flatpak installs
- `--filesystem=home` — to access `~/.local/share/flatpak` user installs
- `--talk-name=org.freedesktop.Flatpak` — to communicate with the Flatpak system daemon

These are justified for a Flatpak manager application. They are covered by exceptions in
`exceptions.json` (`finish-args-home-filesystem-access`, `finish-args-flatpak-spawn-access`).

## Bootstrap: x-skip-install-test

On first build, Saturn is not yet in the testhub index, so the e2e-install CI step would
fail. The manifest includes `x-skip-install-test: true` to bypass this on the first run.

**After the first successful CI run** (which adds Saturn to the index):
1. Remove `x-skip-install-test: true` from `manifest.yaml`
2. Trigger a second build — this time e2e-install will perform a real `flatpak install`

## CL dependency pinning

The 15 Common Lisp library dependencies in the `saturn-cl-deps` module use pinned commits
for reproducibility. Several of these repos (from kolunmi's GitHub) do not use semantic
version tags — they are pinned to specific commits rather than tags.

When bumping CL deps, update both the `commit:` hash and (where present) the `tag:` field.
