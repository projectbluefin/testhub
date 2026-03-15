# LM Studio — Known Issues

## Icon omitted (open problem)

The deb ships `usr/share/icons/hicolor/0x0/apps/lm-studio.png` at 1024×1024.
`flatpak-builder` rejects any icon >512×512 at export time regardless of the hicolor
directory name.

Known failed approaches inside the flatpak-builder sandbox (gnome-49 build-commands):
- `convert` (ImageMagick) — not available in gnome-49
- `python3 gi` / GdkPixbuf — fails; glycin sandboxed loaders unavailable in flatpak-builder
  restricted env
- `ffmpeg` — available but not confirmed working for PNG→PNG resize

**Current workaround:** icon skipped entirely until a working resize tool is confirmed.

To resolve: identify a tool available in gnome-49 build-commands that can resize a PNG
without requiring glycin loaders (e.g. `python3 PIL/Pillow`, `gdk-pixbuf-thumbnailer`,
`magick` from ImageMagick 7). Verify inside a live gnome-49 container before updating the
manifest.

## Builddir lint exceptions

The following `flatpak-builder-lint` checks are suppressed in `exceptions.json`:

- **`appstream-missing-icon-file`** / **`no-exportable-icon-installed`**: icon is omitted
  intentionally (see "Icon omitted" section above). Suppressed until a working resize tool
  is confirmed inside the gnome-49 sandbox.
- **`metainfo-missing-screenshots`**: non-Flathub personal remote; no screenshot mirroring
  infrastructure is required or maintained here.

## `--filesystem=home` (intentional)

LM Studio defaults to `~/.lmstudio` (non-XDG; no XDG support as of v0.4.7) and allows
users to configure a custom model directory anywhere under `$HOME` via the GUI. Tightening
to `--filesystem=~/.lmstudio` would break custom model paths.

Upstream tracker: https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1601

**Flathub would require narrowing filesystem access.** Intentional for this personal remote.

## x86_64 only

Upstream only ships x64 installers. Tracked via `x-arches: [x86_64]` in `manifest.yaml`.

## metainfo release date placeholder

`ai.lmstudio.LMStudio.metainfo.xml` uses a placeholder release date (`2025-03-01` for
v0.4.7) because the upstream changelog only listed entries up to v0.4.6 as of 2026-03-11.
Update when the upstream changelog is updated.

## Renovate cannot auto-update this app

LM Studio uses a non-standard installer URL pattern
(`https://installers.lmstudio.ai/linux/x64/<version>/LM-Studio-<version>-x64.deb`).
Renovate's `github-releases` datasource cannot compute `sha256` for the deb artifact.
`manifest.yaml` must be updated manually on each release: URL, `sha256`, `x-version`,
and the version string inside `build-commands`.

## Proprietary license format

`ai.lmstudio.LMStudio.metainfo.xml` uses `LicenseRef-proprietary=` SPDX format.
`appstreamcli validate` may warn about this. Non-fatal; validation runs with `|| true`.
