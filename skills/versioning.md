# Versioning

Every package must carry an explicit version tag on ghcr.io in addition to `:latest`.

## Tag convention

| Build path | Version source | Tags pushed |
|---|---|---|
| `release.yaml` (bundle-repack) | `version:` field | `latest-<arch>`, `v1.2.3-<arch>`, `stable-<arch>` |
| `manifest.yaml` (flatpak-builder) | `x-version:` field | `latest-<arch>`, `1.2.3-<arch>`, `stable-<arch>` |

## Rules

- `release.yaml` apps: `version` is a required field — CI errors if missing.
- `manifest.yaml` apps: add `x-version: "<version>"` as a top-level field.
  flatpak-builder ignores `x-`-prefixed fields — safe to add.
- If `x-version` is absent, the build warns and pushes `:latest` only.
- Version strings must reflect the actual upstream app version — not build dates,
  git shas, or repo versions.
- When upgrading an app, update `x-version` (or `version`) in the same commit that
  updates the source URL and sha256.

## Source URL convention (manifest.yaml apps)

Always use immutable versioned tag archive URLs:

```
# Correct
https://github.com/ghostty-org/ghostty/archive/refs/tags/v1.3.0.tar.gz

# Wrong — content changes without notice
https://github.com/ghostty-org/ghostty/archive/refs/heads/main.tar.gz
https://github.com/ghostty-org/ghostty/archive/tip.tar.gz
```

Never use rolling `tip`, `latest`, or branch archive URLs. Find the exact tag URL and
update sha256 in the same commit.
