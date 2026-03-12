# App Gotchas

Per-app known issues and workarounds. Each app has a dedicated `GOTCHAS.md` in its
`flatpaks/<app>/` directory — load that file when working on the relevant app.

| App | File | Key issues |
|---|---|---|
| ghostty | `flatpaks/ghostty/GOTCHAS.md` | sandbox escape (`--talk-name=org.freedesktop.Flatpak`), aggressive `*.so`/`*.a` cleanup globs |
| goose | `flatpaks/goose/GOTCHAS.md` | bundle-repack (no metainfo inject), x86_64 only, missing `<categories>` (Flathub-only violation) |
| io.github.DenysMb.Kontainer | (inline in `app-gotchas.md`) | `appstream-external-screenshot-url` + `appstream-screenshots-not-mirrored-in-ostree` — screenshots not mirrored to Flathub CDN; permanent exception (both stages) |
| lmstudio | `flatpaks/lmstudio/GOTCHAS.md` | icon omitted (resize unsolved), `--filesystem=home` intentional, x86_64 only, manual Renovate required |
| firefox-nightly | `flatpaks/firefox-nightly/GOTCHAS.md` | app-id is `org.mozilla.firefox.nightly` (renamed from `org.mozilla.firefox` to avoid Flathub clash), rolling aarch64 sha256, BaseApp required pre-install, `.appdata.xml` skips CI validation |
| thunderbird-nightly | `flatpaks/thunderbird-nightly/GOTCHAS.md` | x86_64 only (no aarch64), comm-central icon pinning — verify each size sha256 independently (swap of 32/64 was a bug), `--persist=.thunderbird-nightly` profile isolation, no BaseApp pre-install needed, extension stubs created in build-commands (not cleanup-commands) |
| virtualbox | `flatpaks/virtualbox/GOTCHAS.md` | KVM backend (no vboxdrv kernel module), X11 only (VBoxSVGA Wayland bug), hardening disabled, gsoap serial build, shared-modules SDL1+GLU inlined |
| org.altlinux.Tuner | (inline in `app-gotchas.md`) | `libpeas` 2.x requires `-Dgjs=false` on GNOME Platform 49 (mozjs-128 not available) |

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

### io.github.DenysMb.Kontainer

- `appstream-external-screenshot-url` + `appstream-screenshots-not-mirrored-in-ostree`:
  Upstream appstream metadata contains screenshots hosted at external URLs (not mirrored
  to `https://dl.flathub.org/media`). This is a permanent exception — the app is not on
  Flathub so screenshot mirroring never happens. Both exceptions declared in
  `flatpaks/io.github.DenysMb.Kontainer/exceptions.json`.
  - `appstream-external-screenshot-url` fires at the `builddir` lint stage
  - `appstream-screenshots-not-mirrored-in-ostree` fires at the `repo` lint stage
  Both must be present; omitting either causes the x86_64 build to fail.

## gnome-49 container: dbus setup required for e2e-install

The `e2e-install` job runs in `ghcr.io/flathub-infra/flatpak-github-actions:gnome-49`.
This container is missing the `messagebus` system user and has no `useradd`/`adduser`.
`flatpak install` requires a running dbus session bus or it will fail.

Full setup sequence (must run before `flatpak install`):

```bash
# 1. Create machine-id
mkdir -p /var/lib/dbus && dbus-uuidgen | tee /var/lib/dbus/machine-id

# 2. Create socket dir (gnome-49 uses /app as Flatpak prefix)
mkdir -p /app/var/run/dbus

# 3. Add messagebus user/group — no useradd; write /etc/passwd and /etc/group directly
grep -q '^messagebus:' /etc/group  || echo 'messagebus:x:111:'                  >> /etc/group
grep -q '^messagebus:' /etc/passwd || echo 'messagebus:x:111:111::/:/sbin/nologin' >> /etc/passwd

# 4. Start system bus
dbus-daemon --system --fork

# 5. Start session bus and export to GITHUB_ENV
eval "$(dbus-launch --sh-syntax)"
echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}" >> "$GITHUB_ENV"
```

Key constraints:
- Socket path prefix is `/app/var/run/dbus` (not `/var/run/dbus`) — gnome-49 flatpak prefix
- `eval $(dbus-launch --sh-syntax)` sets `DBUS_SESSION_BUS_ADDRESS` in the current shell;
  the `>> $GITHUB_ENV` export makes it available to subsequent job steps
- Must run in the same step as the dbus-daemon start, before `flatpak install`

## Electron GUI apps: x-skip-launch-check required

Electron apps (e.g. goose, lmstudio) run as root in the CI container and require a display
to initialize (X11/Wayland). In the headless gnome-49 container:

- `zypak-wrapper` segfaults with exit 139 even with `--no-sandbox`
- The Ozone X11 platform fails: `Missing X server or $DISPLAY`

**Fix:** set `x-skip-launch-check: true` in `release.yaml` (or `manifest.yaml`). The
launch check step reads this field and exits 0 with a SKIP message. The install step
already validates that the Flatpak installs correctly.

```yaml
# In release.yaml or manifest.yaml:
x-skip-launch-check: true
```

Applies to: **goose**, **lmstudio** (any Electron GUI app).

## org.altlinux.Tuner

### libpeas 2.x: `-Dgjs=false` required on GNOME Platform 49

`libpeas` 2.0.x depends on `gjs` (GNOME JavaScript), which requires SpiderMonkey
(`mozjs-128`). `mozjs-128` is **not included** in `org.gnome.Platform//49`, so the
`libpeas` build fails on any clean x86_64 build with:

```
meson: error: Dependency "mozjs-128" not found
```

**Fix:** add `-Dgjs=false` to the `libpeas` module's `config-opts`:

```yaml
- name: libpeas
  buildsystem: meson
  config-opts:
    - -Dgjs=false
    # ... other opts
```

This disables the GJS plugin loader; Tuner does not use it, so functionality is unaffected.

**Why aarch64 may pass while x86_64 fails:** flatpak-builder caches build artifacts
by content hash. If a prior aarch64 build of `libpeas` was cached before the mozjs-128
check was enforced, the cached result is reused and the step appears to pass. A clean
build (no cache) will reproduce the failure on both arches.

## bundle-repack apps: no metainfo injection

The `release.yaml` pipeline downloads a pre-built upstream `.flatpak` and repackages it as
OCI. There is no mechanism to inject source-side files (e.g. metainfo XML) into the bundle.

Metainfo XML files committed to `flatpaks/<app>/` are source-side assets only — they will
not appear in the installed Flatpak unless the upstream bundle already includes them.

Applies to: **goose** (bundle-repack path). All other apps use `manifest.yaml`
(flatpak-builder) and install metainfo directly.
