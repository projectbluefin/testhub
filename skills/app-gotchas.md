# App Gotchas

Per-app known issues and workarounds.

## bundle-repack apps: no metainfo injection

The `release.yaml` pipeline downloads a pre-built upstream `.flatpak` and repackages it as
OCI. There is no mechanism to inject source-side files (e.g. `metainfo.xml`) into the bundle.

Metainfo XML files committed to `flatpaks/<app>/` are source-side assets only — they will
not appear in the installed Flatpak unless the upstream bundle already includes them. This is
a known limitation of the bundle-repack path.

To ship metainfo for a bundle-repack app: either the upstream `.flatpak` must include it, or
the app must be migrated to the `manifest.yaml` (flatpak-builder) path.

## firefox-nightly

**aarch64 sha256 is intentionally rolling-stale.** The manifest uses
`latest-mozilla-central` rolling URLs — the sha256 for aarch64 becomes stale daily by
design. Do not attempt to pin sha256 for nightly builds. Document in the manifest that the
aarch64 sha256 must be refreshed on each build loop.

**Requires `org.mozilla.firefox.BaseApp//24.08` pre-installed in the build container.**
The `freedesktop-24.08` runtime (used by gnome-49) does not include this BaseApp by default.
In a clean environment, `just loop firefox-nightly` fails with "BaseApp not installed".

Fix — inside the gnome-49 build container before invoking flatpak-builder:
```bash
flatpak install --user flathub org.mozilla.firefox.BaseApp//24.08
```

This also means `just loop-all` will fail for firefox-nightly on first run in clean environments.

**hg.mozilla.org JSON API:** The key for changesets is `changesets`, not `entries`.
Correct extraction:
```bash
python3 -c "import sys,json; data=json.load(sys.stdin); print(data['changesets'][0]['node'])"
```
Also: hg.mozilla.org redirects to hg-edge — always pass `-L` to curl.

## lmstudio

**Icon is 1024×1024; resize to 512×512 is an open problem.**
The deb ships `usr/share/icons/hicolor/0x0/apps/lm-studio.png` at 1024×1024.
flatpak-builder rejects any icon >512×512 at export time regardless of hicolor directory name.

Known failed approaches inside the flatpak-builder sandbox (gnome-49 build-commands):
- `convert` (ImageMagick) — not available in gnome-49
- `python3 gi` / GdkPixbuf — fails; glycin sandboxed loaders unavailable in flatpak-builder restricted env
- `ffmpeg` — available but not confirmed working for PNG→PNG resize

**Current workaround:** icon skipped entirely until a working resize tool is confirmed.
To resolve: identify a tool available in gnome-49 build-commands that can resize a PNG
without requiring glycin loaders (e.g. `python3 PIL/Pillow`, `gdk-pixbuf-thumbnailer`,
`magick` from ImageMagick 7). Verify inside a live gnome-49 container before updating the manifest.

**metainfo release date placeholder:** `flatpaks/lmstudio/metainfo.xml` uses a placeholder
release date (`2025-03-01` for v0.4.7) because upstream changelog only listed entries up to
v0.4.6 as of 2026-03-11. Update when the upstream changelog is updated.

## goose

**chunkah layer count (~200MB): ~30 layers** from OSTree object store heuristics alone.
xattr-based component hints deferred until repo has 3+ packages.
