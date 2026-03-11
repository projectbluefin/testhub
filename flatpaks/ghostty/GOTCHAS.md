# Ghostty — Known Issues

## Sandbox escape (intentional)

`--talk-name=org.freedesktop.Flatpak` grants a full sandbox escape so the terminal emulator
can launch host processes (shells, editors, arbitrary commands). Without it Ghostty cannot
function as a terminal.

**Flathub would reject this outright.** This repo is a personal OCI remote, not a Flathub
submission. The exception is acceptable here but must never be proposed to Flathub.

If Ghostty is ever submitted to Flathub the sandbox escape must be removed or replaced with
a portal-based mechanism. Track the upstream issue tracker for portal support.

## Aggressive cleanup globs

`cleanup` includes `"*.so"` and `"*.a"`. This is safe because Zig links statically — no
runtime `.so` files are needed. If any future module adds a shared-lib dependency these
globs will silently strip it. Verify after any new module is added.

## `--device=all`

Required for GPU (Vulkan) and PTY device access. Flathub would require narrowing this to
specific devices. Intentional for now.
