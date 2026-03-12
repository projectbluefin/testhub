# App Gotchas

Per-app known issues and workarounds. Each app has a dedicated `GOTCHAS.md` in its
`flatpaks/<app>/` directory — load that file when working on the relevant app.

| App | File | Key issues |
|---|---|---|
| ghostty | `flatpaks/ghostty/GOTCHAS.md` | sandbox escape (`--talk-name=org.freedesktop.Flatpak`), aggressive `*.so`/`*.a` cleanup globs |
| goose | `flatpaks/goose/GOTCHAS.md` | bundle-repack (no metainfo inject), x86_64 only, missing `<categories>` (Flathub-only violation) |
| lmstudio | `flatpaks/lmstudio/GOTCHAS.md` | icon omitted (resize unsolved), `--filesystem=home` intentional, x86_64 only, manual Renovate required |
| firefox-nightly | `flatpaks/firefox-nightly/GOTCHAS.md` | app-id is `org.mozilla.firefox.nightly` (renamed from `org.mozilla.firefox` to avoid Flathub clash), rolling aarch64 sha256, BaseApp required pre-install, `.appdata.xml` skips CI validation |
| thunderbird-nightly | `flatpaks/thunderbird-nightly/GOTCHAS.md` | x86_64 only (no aarch64), comm-central icon pinning — verify each size sha256 independently (swap of 32/64 was a bug), `--persist=.thunderbird-nightly` profile isolation, no BaseApp pre-install needed, extension stubs created in build-commands (not cleanup-commands) |
| virtualbox | `flatpaks/virtualbox/GOTCHAS.md` | KVM backend (no vboxdrv kernel module), X11 only (VBoxSVGA Wayland bug), hardening disabled, gsoap serial build, shared-modules SDL1+GLU inlined |

## Flatpak install scope — always system-wide

When installing any app for manual testing or validation, always install system-wide.
Never pass `--user`.

```bash
# Correct
flatpak install <remote> <app-id>

# Wrong — never use --user
flatpak --user install <remote> <app-id>
```

If an upstream doc or CI example uses `--user`, ignore it and use system-wide instead.

## flatpak-tracker issue body format

Real flatpak-tracker runtime-update issue bodies use:

- **Single-slash runtime format with arch triplet:** `org.gnome.Platform/x86_64/49`
  (NOT double-slash `org.gnome.Platform//49` — the arch field is always present)
- **Backtick-quoted field values:** e.g. `` **Package:** `app/com.foo.Bar` ``

`sync-runtime-issues.py` regex patterns must:
1. Parse the full triplet format `<runtime>/<arch>/<version>`
2. Strip surrounding backticks from `Package:` and runtime field values before processing

Applies to: `scripts/sync-runtime-issues.py` and any task spec describing issue body format.

## bundle-repack apps: no metainfo injection

The `release.yaml` pipeline downloads a pre-built upstream `.flatpak` and repackages it as
OCI. There is no mechanism to inject source-side files (e.g. metainfo XML) into the bundle.

Metainfo XML files committed to `flatpaks/<app>/` are source-side assets only — they will
not appear in the installed Flatpak unless the upstream bundle already includes them.

Applies to: **goose** (bundle-repack path). All other apps use `manifest.yaml`
(flatpak-builder) and install metainfo directly.
