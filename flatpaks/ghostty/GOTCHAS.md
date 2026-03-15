# Ghostty — Known Issues

## Sandbox escape (intentional)

`--talk-name=org.freedesktop.Flatpak` grants a full sandbox escape so the terminal emulator
can launch host processes (shells, editors, arbitrary commands). Without it Ghostty cannot
function as a terminal.

**Flathub would reject this outright.** This repo is a personal OCI remote, not a Flathub
submission. The exception is acceptable here but must never be proposed to Flathub.

If Ghostty is ever submitted to Flathub the sandbox escape must be removed or replaced with
a portal-based mechanism. Track the upstream issue tracker for portal support.

## 10-second first-launch-after-boot delay (GNOME Wayland)

**Symptom:** Ghostty takes ~10 seconds to open its window on the first launch after each
boot on GNOME Wayland.

**Confirmed root cause:** `FlatpakHostCommand` via `org.freedesktop.Flatpak.Development`
blocks for ~10 seconds on the first call after boot.

Ghostty (`-Dflatpak=true`) detects it is running in a flatpak and calls
`FlatpakHostCommand` to run `/bin/sh -l -c "getent passwd <username>"` on the host
in order to discover the user's login shell and home directory
(`src/os/passwd.zig::get()`).  The first `HostCommand` call cold-starts
flatpak-session-helper's host-execution infrastructure and blocks for ~10 s.
Subsequent calls in the same session are fast.

**D-Bus timeline (full unfiltered capture):**
```
+0.310s  Hello          ghostty registers on session bus
+0.723s  RequestSession flatpak-session-helper (already running — fast)
+0.744s  HostCommand    org.freedesktop.Flatpak.Development  ← BLOCKS
+10.87s  HostCommandExited                                   ← 10.1 s later
+10.99s  HostCommand    (second call — fast)
```

**Why `RequestSession` does not help:**
`RequestSession` is on `org.freedesktop.Flatpak.SessionHelper`.
`HostCommand` is on `org.freedesktop.Flatpak.Development`.
These are different interfaces; pre-warming SessionHelper does **not** pre-warm Development.

**Investigation status:** delay persists with `--filesystem=home:ro` and `--device=dri`
matching the upstream ghostty flatpak manifest — permissions are not the cause.
Root cause is in the `FlatpakHostCommand` first-call cold-start within flatpak-session-helper.
Consider reporting upstream to ghostty: the `/bin/sh -l -c "getent passwd"` call should
either be cached after the first successful lookup or made asynchronous.

**Diagnosis commands:**
```bash
# Capture full unfiltered D-Bus session bus traffic during ghostty launch
dbus-monitor --session 2>/dev/null | ts '%.s' > /tmp/dbus-full.log &
MONITOR_PID=$!
flatpak run --user com.mitchellh.ghostty &
sleep 15
kill $MONITOR_PID
grep -E 'HostCommand|Flatpak|portal|ghostty' /tmp/dbus-full.log | head -40

# Time the exact command ghostty runs via HostCommand
time /bin/sh -c "getent passwd $USER"   # fast
time /bin/sh -l -c "getent passwd $USER"  # may be slow if login shell is slow

# Check user journal for flatpak-session-helper activation
journalctl --user -xe | grep -E 'flatpak' | tail -20
```

## Aggressive cleanup globs

`cleanup` includes `"*.so"` and `"*.a"`. This is safe because Zig links statically — no
runtime `.so` files are needed. If any future module adds a shared-lib dependency these
globs will silently strip it. Verify after any new module is added.

## `--device=dri` + `--device=all`

`--device=all` grants GPU (Vulkan), PTY device access, and host PTS namespace access
(needed for `FlatpakHostCommand` PTY passing). `--device=dri` is explicit for 3D
rendering. Both match the upstream ghostty flatpak manifest. Flathub would require
narrowing — intentional for now.

## exceptions.json — lint suppressions

In addition to the standard non-Flathub exceptions, ghostty suppresses:

| Exception | Reason |
|---|---|
| `finish-args-home-ro-filesystem-access` | Matches upstream ghostty flatpak manifest; needed while investigating cold-start delay |
| `finish-args-flatpak-spawn-access` | Required for sandbox escape (see above) — linter flags it, intentional |
| `metainfo-missing-screenshots` | Personal hosting repo — no screenshots maintained |
