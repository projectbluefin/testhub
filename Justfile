set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    just --list

# === Configuration ===
container_image := "ghcr.io/flathub-infra/flatpak-github-actions:gnome-49"
local_registry := "localhost:5000"

# === Build recipes ===

# Build app and push to ghcr.io with zstd:chunked compression
build app="ghostty":
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{app}}"
    MANIFEST="flatpaks/${APP}/manifest.yaml"
    [[ -f "${MANIFEST}" ]] || { echo "ERROR: ${MANIFEST} not found" >&2; exit 1; }
    APP_ID=$(python3 -c "
    import sys
    for line in open(sys.argv[1]):
        line = line.strip()
        if line.startswith('app-id:'):
            print(line.split(':', 1)[1].strip())
            break
    " "${MANIFEST}")
    [[ -n "${APP_ID}" ]] || { echo "ERROR: could not determine app-id from ${MANIFEST}" >&2; exit 1; }
    ARCH=$(uname -m)
    REF="app/${APP_ID}/${ARCH}/stable"
    OCI_DIR=".${APP}.oci"
    echo "==> Building ${REF}"
    echo "==> mode: full (ghcr.io push)"
    # Ensure container image is cached
    podman image exists "{{container_image}}" || podman pull "{{container_image}}"
    # flatpak-builder inside gnome-49 container
    # SOURCE_DATE_EPOCH=0: normalises tar timestamps for deterministic OCI blob hashes
    # --override-source-date-epoch=0: makes OSTree commit timestamps deterministic
    podman run --rm --privileged \
      -v "$(pwd):/workspace:z" -w /workspace \
      -e SOURCE_DATE_EPOCH=0 \
      "{{container_image}}" \
      flatpak-builder \
        --disable-rofiles-fuse --force-clean \
        --override-source-date-epoch=0 \
        --repo=.ostree-repo \
        .build-dir "${MANIFEST}"
    # OCI export — SOURCE_DATE_EPOCH=0 is sufficient for build-bundle (reads env directly)
    # Do NOT pass --override-source-date-epoch to build-bundle — it is a flatpak-builder-only flag
    rm -rf "${OCI_DIR}"
    podman run --rm --privileged \
      -v "$(pwd):/workspace:z" -w /workspace \
      -e SOURCE_DATE_EPOCH=0 \
      "{{container_image}}" \
      flatpak build-bundle --oci .ostree-repo "${OCI_DIR}" "${REF}"
    # Push to local registry for label verification
    skopeo copy --dest-tls-verify=false \
      --digestfile "/tmp/${APP}-digest.txt" \
      "oci:./${OCI_DIR}" \
      "docker://{{local_registry}}/castrojo/jorgehub/${APP}:latest"
    DIGEST=$(cat "/tmp/${APP}-digest.txt")
    echo "==> Local digest: ${DIGEST}"
    # Verify labels
    skopeo inspect --tls-verify=false \
      "docker://{{local_registry}}/castrojo/jorgehub/${APP}@${DIGEST}" \
      | python3 -c "
    import json, sys
    d = json.load(sys.stdin)
    labels = d.get('Labels', {})
    for k in ['org.flatpak.ref', 'org.flatpak.metadata']:
        s = 'OK' if k in labels else 'MISSING'
        print(f'{s}: {k}')
        if s == 'MISSING': sys.exit(1)
    print('All required labels present.')
    "
    # Load OCI into podman image store (--quiet: output image ID only, no progress noise)
    IMAGE_ID=$(podman pull --quiet "oci:./${OCI_DIR}")
    echo "==> Image ID: ${IMAGE_ID}"
    gh auth token | podman login ghcr.io --username castrojo --password-stdin
    podman push --compression-format=zstd:chunked \
      --digestfile "/tmp/${APP}-ghcr-digest.txt" \
      "${IMAGE_ID}" "docker://ghcr.io/castrojo/jorgehub/${APP}:latest-${ARCH}"
    GHCR_DIGEST=$(cat "/tmp/${APP}-ghcr-digest.txt")
    echo "==> ghcr.io digest: ${GHCR_DIGEST}"
    # Verify zstd:chunked
    skopeo inspect --raw "docker://ghcr.io/castrojo/jorgehub/${APP}:latest-${ARCH}" \
      | python3 -c "
    import json, sys
    d = json.load(sys.stdin)
    for i, l in enumerate(d.get('layers', [])):
        mt = l.get('mediaType', '')
        ann = l.get('annotations', {})
        chunked = 'io.github.containers.zstd-chunked.manifest' in ann
        print(f'Layer {i}: {mt}  zstd={\"zstd\" in mt}  chunked={chunked}')
    "
    echo "==> Done. ghcr.io/castrojo/jorgehub/${APP}:latest-${ARCH} @ ${GHCR_DIGEST}"

# Loop: build + local registry only (no ghcr push) — dev iteration target
loop app="ghostty":
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{app}}"
    MANIFEST="flatpaks/${APP}/manifest.yaml"
    [[ -f "${MANIFEST}" ]] || { echo "ERROR: ${MANIFEST} not found" >&2; exit 1; }
    APP_ID=$(python3 -c "
    import sys
    for line in open(sys.argv[1]):
        line = line.strip()
        if line.startswith('app-id:'):
            print(line.split(':', 1)[1].strip())
            break
    " "${MANIFEST}")
    [[ -n "${APP_ID}" ]] || { echo "ERROR: could not determine app-id from ${MANIFEST}" >&2; exit 1; }
    ARCH=$(uname -m)
    REF="app/${APP_ID}/${ARCH}/stable"
    OCI_DIR=".${APP}.oci"
    echo "==> Building ${REF}"
    echo "==> mode: LOCAL_ONLY"
    podman image exists "{{container_image}}" || podman pull "{{container_image}}"
    podman run --rm --privileged \
      -v "$(pwd):/workspace:z" -w /workspace \
      -e SOURCE_DATE_EPOCH=0 \
      "{{container_image}}" \
      flatpak-builder \
        --disable-rofiles-fuse --force-clean \
        --override-source-date-epoch=0 \
        --disable-download \
        --repo=.ostree-repo \
        .build-dir "${MANIFEST}"
    rm -rf "${OCI_DIR}"
    podman run --rm --privileged \
      -v "$(pwd):/workspace:z" -w /workspace \
      -e SOURCE_DATE_EPOCH=0 \
      "{{container_image}}" \
      flatpak build-bundle --oci .ostree-repo "${OCI_DIR}" "${REF}"
    skopeo copy --dest-tls-verify=false \
      --digestfile "/tmp/${APP}-digest.txt" \
      "oci:./${OCI_DIR}" \
      "docker://{{local_registry}}/castrojo/jorgehub/${APP}:latest"
    DIGEST=$(cat "/tmp/${APP}-digest.txt")
    echo "==> Local digest: ${DIGEST}"
    skopeo inspect --tls-verify=false \
      "docker://{{local_registry}}/castrojo/jorgehub/${APP}@${DIGEST}" \
      | python3 -c "
    import json, sys
    d = json.load(sys.stdin)
    labels = d.get('Labels', {})
    for k in ['org.flatpak.ref', 'org.flatpak.metadata']:
        s = 'OK' if k in labels else 'MISSING'
        print(f'{s}: {k}')
        if s == 'MISSING': sys.exit(1)
    print('All required labels present.')
    "
    echo "==> LOCAL_ONLY done. ${DIGEST}"

# Update gh-pages index from latest ghcr.io digest and push
update-index app="ghostty":
    #!/usr/bin/env bash
    set -euo pipefail
    ARCH=$(uname -m)
    DIGEST=$(cat /tmp/{{app}}-ghcr-digest.txt)
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    git worktree add /tmp/jorgehub-pages gh-pages 2>/dev/null || true
    cd /tmp/jorgehub-pages && python3 "${REPO_ROOT}/scripts/update-index.py" \
      --app {{app}} \
      --digest "${DIGEST}" \
      --registry ghcr.io \
      --tags "latest-${ARCH}"
    git -C /tmp/jorgehub-pages add index/static
    git -C /tmp/jorgehub-pages diff --cached --quiet && echo "index unchanged, skipping commit" || \
      git -C /tmp/jorgehub-pages commit -m "feat(index): update {{app}} to ${DIGEST:0:19}"
    git -C /tmp/jorgehub-pages push origin gh-pages
    git worktree remove /tmp/jorgehub-pages --force

# Validate index/static JSON is well-formed
check-index:
    python3 scripts/update-index.py --validate

# E2E: add remote, list apps, confirm app is visible
verify app="ghostty":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Adding jorgehub remote..."
    flatpak remote-add --user --if-not-exists jorgehub \
      oci+https://castrojo.github.io/jorgehub
    echo "==> Listing apps from jorgehub remote..."
    flatpak remote-ls --user jorgehub
    echo "==> Looking for {{app}}..."
    flatpak remote-ls --user jorgehub | grep -i "{{app}}" \
      && echo "==> {{app}} found in jorgehub remote!" \
      || { echo "ERROR: {{app}} not found"; exit 1; }
