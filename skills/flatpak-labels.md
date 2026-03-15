# Flatpak Labels

## When to Use
- Adding or changing OCI labels or annotations
- Debugging `flatpak install` failures caused by missing labels
- Verifying label preservation across chunkah

## When NOT to Use
- Build pipeline mechanics → `skills/pipeline.md`
- Index/gh-pages → `skills/gh-pages-index.md`

## Labels vs Annotations

The Flatpak client reads **Labels** only — not OCI annotations. `org.flatpak.ref` and
`org.flatpak.metadata` must be in the image's Config Labels, not in manifest annotations.

Verify after every push:

```bash
skopeo inspect --tls-verify=false "docker://localhost:5000/<org>/<repo>/<app>@<digest>" \
  | jq '.Labels["org.flatpak.ref"], .Labels["org.flatpak.metadata"]'
```

Both must be non-null. A null here means `flatpak install` will fail or produce a 404 even
if CI passed.

## Required labels

Every pushed image must carry all of these:

| Label | Source |
|---|---|
| `org.flatpak.ref` | Set by `flatpak build-bundle` — must survive chunkah |
| `org.flatpak.metadata` | Set by `flatpak build-bundle` — must survive chunkah |
| `org.opencontainers.image.created` | Set by `just _apply-oci-labels` |
| `org.opencontainers.image.version` | Set by `just _apply-oci-labels` (when VERSION non-empty) |
| `org.opencontainers.image.source` | Set by `just _apply-oci-labels` (bundle-repack path) |

## Label preservation across chunkah

chunkah passes labels through via `CHUNKAH_CONFIG_STR`. Labels applied **after** this
variable is captured are silently dropped.

Correct order:
1. Build OCI dir → load into podman → `IMAGE_ID`
2. Apply OCI labels via `just _apply-oci-labels` → new `IMAGE_ID`
3. Capture `CHUNKAH_CONFIG_STR=$(podman inspect "${IMAGE_ID}" | jq -c '.[0]')`
4. Run chunkah with `-e CHUNKAH_CONFIG_STR`

Never capture `CHUNKAH_CONFIG_STR` from the pre-label image and then apply labels — the
labels will not be in the config string and will be lost.

## Verification after loop

```bash
# 1. Check labels in local registry
skopeo inspect --tls-verify=false "docker://localhost:5000/<org>/<repo>/<app>@<digest>" \
  | jq -e '
    .Labels["org.flatpak.ref"] // error("MISSING: org.flatpak.ref"),
    .Labels["org.flatpak.metadata"] // error("MISSING: org.flatpak.metadata"),
    .Labels["org.opencontainers.image.created"] // error("MISSING: created")
    | "OK: \(.)"
  '

# 2. Check layers are zstd:chunked (build path only)
skopeo inspect --raw "docker://ghcr.io/<org>/<repo>/<app>:latest-<arch>" \
  | jq -r '.layers[] | "Layer \(.digest[:19]): chunked=\((.annotations // {}) | has("io.github.containers.zstd-chunked.manifest-checksum"))"'
```
