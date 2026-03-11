# Firefox Nightly — Known Issues

## aarch64 sha256 is intentionally stale

The manifest uses `latest-mozilla-central` rolling URLs. The `sha256` for aarch64 becomes
stale daily by design. Do not attempt to permanently pin sha256 for nightly builds.
Refresh the aarch64 sha256 on each build loop iteration.

## Requires BaseApp pre-installed in build container

`flatpak-builder` requires `org.mozilla.firefox.BaseApp//24.08` to be installed before
building. The `freedesktop-24.08` runtime (used by gnome-49) does not include this BaseApp
by default.

In a clean environment `just loop firefox-nightly` fails with "BaseApp not installed".

Fix — inside the gnome-49 build container before invoking flatpak-builder:
```bash
flatpak install --user flathub org.mozilla.firefox.BaseApp//24.08
```

This also means `just loop-all` will fail for firefox-nightly on first run in clean
environments.

## `.appdata.xml` extension skips validation

The metainfo file is named `org.mozilla.firefox.appdata.xml` (legacy extension). The
`appstreamcli validate` step in `build.yml` globs for `*.metainfo.xml` — this file is
**silently skipped** by that validation step. Not a build error, but means metainfo
correctness is unverified by CI.

If the file is ever renamed to `.metainfo.xml`, re-run validation to surface any issues.

## hg.mozilla.org API key

When fetching the current Mercurial revision, the JSON API key is `changesets`, not
`entries`. Always pass `-L` to curl (hg.mozilla.org redirects to hg-edge):
```bash
curl -fsSL "https://hg.mozilla.org/mozilla-central/json-log/tip" \
  | python3 -c "import sys,json; data=json.load(sys.stdin); print(data['changesets'][0]['node'])"
```

## Icon revision pinning

Icons are pinned to a specific Mercurial revision hash in `manifest.yaml` (see comment
at line 95). When bumping `x-version`, update the revision hash and all six icon `sha256`
values. The revision must be a commit that contains the branding assets for the new version.

## BaseApp dependency on freedesktop runtime (not GNOME)

Firefox Nightly uses `org.freedesktop.Platform//24.08` + `org.mozilla.firefox.BaseApp`,
not the GNOME runtime used by the other apps. The build container must use
`ghcr.io/flathub-infra/flatpak-github-actions:freedesktop-24.08` (set via
`x-container-image` in `manifest.yaml`).
