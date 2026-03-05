#!/usr/bin/env bash
# build-local.sh — build a flatpak app using the gnome-49 container and push to local registry
# Usage:
#   build-local.sh [app]              # build + push to ghcr.io
#   LOCAL_ONLY=1 build-local.sh [app] # build + local registry only (no ghcr push)
set -euo pipefail

REGISTRY="localhost:5000"
APP="${1:-ghostty}"
MANIFEST="flatpaks/${APP}/manifest.yaml"
CONTAINER_IMAGE="ghcr.io/flathub-infra/flatpak-github-actions:gnome-49"
LOCAL_ONLY="${LOCAL_ONLY:-0}"

# Resolve app-id from manifest
APP_ID=$(python3 -c "
import sys
# Simple YAML key extraction without PyYAML dependency
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith('app-id:'):
        print(line.split(':', 1)[1].strip())
        break
" "${MANIFEST}")

ARCH=$(uname -m)
BRANCH="stable"
REF="app/${APP_ID}/${ARCH}/${BRANCH}"
BUILD_DIR=".build-dir"
OSTREE_REPO=".ostree-repo"
OCI_DIR=".${APP}.oci"

echo "==> app-id:  ${APP_ID}"
echo "==> ref:     ${REF}"
echo "==> image:   ${CONTAINER_IMAGE}"

# Ensure container image is present
podman pull "${CONTAINER_IMAGE}"

# Run flatpak-builder inside the container
# --privileged needed for ostree/fuse operations; --disable-rofiles-fuse avoids fuse requirement
podman run --rm \
  --privileged \
  -v "$(pwd):/workspace:z" \
  -w /workspace \
  "${CONTAINER_IMAGE}" \
  flatpak-builder \
    --disable-rofiles-fuse \
    --force-clean \
    --repo="${OSTREE_REPO}" \
    "${BUILD_DIR}" \
    "${MANIFEST}"

echo "==> Build complete. Exporting OCI image..."
rm -rf "${OCI_DIR}"

# Export from OSTree repo to OCI Image Layout
podman run --rm \
  --privileged \
  -v "$(pwd):/workspace:z" \
  -w /workspace \
  "${CONTAINER_IMAGE}" \
  flatpak build-bundle \
    --oci \
    "${OSTREE_REPO}" \
    "${OCI_DIR}" \
    "${REF}"

echo "==> Pushing to local registry (label verification)..."
skopeo copy \
  --dest-tls-verify=false \
  --digestfile "/tmp/${APP}-digest.txt" \
  "oci:./${OCI_DIR}" \
  "docker://${REGISTRY}/castrojo/jorgehub/${APP}:latest"

DIGEST=$(cat "/tmp/${APP}-digest.txt")
echo "==> Local digest: ${DIGEST}"

echo "==> Inspecting labels..."
skopeo inspect \
  --tls-verify=false \
  "docker://${REGISTRY}/castrojo/jorgehub/${APP}@${DIGEST}" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
labels = d.get('Labels', {})
required = ['org.flatpak.ref', 'org.flatpak.metadata']
ok = True
for k in required:
    status = 'OK' if k in labels else 'MISSING'
    if status == 'MISSING':
        ok = False
    print(f'{status}: {k}')
if ok:
    print('All required labels present.')
else:
    print('ERROR: missing required labels — flatpak client will not see this image.')
    sys.exit(1)
"

if [[ "${LOCAL_ONLY}" == "1" ]]; then
  echo "==> LOCAL_ONLY mode — skipping ghcr.io push."
  echo "==> Done. Local image: ${REGISTRY}/castrojo/jorgehub/${APP}:latest @ ${DIGEST}"
  exit 0
fi

echo "==> Loading OCI dir into podman image store..."
IMAGE_ID=$(podman pull "oci:./${OCI_DIR}" 2>&1 | tail -1)
echo "==> Image ID: ${IMAGE_ID}"

echo "==> Pushing to ghcr.io with zstd:chunked (podman recompresses)..."
gh auth token | podman login ghcr.io --username castrojo --password-stdin
podman push \
  --compression-format=zstd:chunked \
  --digestfile "/tmp/${APP}-ghcr-digest.txt" \
  "${IMAGE_ID}" \
  "docker://ghcr.io/castrojo/jorgehub/${APP}:latest"

GHCR_DIGEST=$(cat "/tmp/${APP}-ghcr-digest.txt")
echo "==> ghcr.io digest: ${GHCR_DIGEST}"

echo "==> Verifying zstd:chunked on ghcr.io..."
skopeo inspect --raw \
  "docker://ghcr.io/castrojo/jorgehub/${APP}:latest" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
layers = d.get('layers', [])
all_zstd = True
for i, layer in enumerate(layers):
    mt = layer.get('mediaType', '')
    ann = layer.get('annotations', {})
    chunked = 'io.github.containers.zstd-chunked.manifest' in ann
    zstd = 'zstd' in mt
    if not zstd:
        all_zstd = False
    print(f'Layer {i}: {mt}  zstd={zstd}  chunked_annotation={chunked}')
if all_zstd:
    print('zstd:chunked: VERIFIED')
else:
    print('WARNING: not all layers are zstd')
"

echo "==> Done. Image: ghcr.io/castrojo/jorgehub/${APP}:latest"
