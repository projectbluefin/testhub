# Goose — Known Issues

## x86_64 only

Upstream ships only an x86_64 `.flatpak` bundle. No aarch64 build is available. Tracked in
`release.yaml` via `arches: [x86_64]`.

## bundle-repack: metainfo not injectable

Goose uses the `release.yaml` (bundle-repack) path. There is no mechanism to inject
source-side files (e.g. `io.github.block.Goose.metainfo.xml`) into a pre-built bundle.
The metainfo XML committed to this directory will **not** appear in the installed Flatpak
unless the upstream bundle already includes it.

To ship updated metainfo: either the upstream `.flatpak` must include it, or goose must be
migrated to the `manifest.yaml` (flatpak-builder) path.

## Missing `<categories>` in metainfo

`io.github.block.Goose.metainfo.xml` does not include a `<categories>` element. Flathub
requires at least one category. This is a documentation-only violation — it does not affect
build or runtime behaviour in this personal remote.

## chunkah layer count

16 layers configured (`chunkah-max-layers: "16"`). At ~200MB the OSTree object store
heuristics alone may produce ~30 layers. If chunkah warns about exceeding the layer budget,
increase `chunkah-max-layers` or enable xattr-based component hints once the repo has 3+
packages.
