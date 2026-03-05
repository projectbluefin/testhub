#!/usr/bin/env bash
# build-local.sh — build a flatpak app using the gnome-49 container and push to local registry
set -euo pipefail

REGISTRY="localhost:5000"
APP="${1:-ghostty}"
MANIFEST="flatpaks/${APP}/manifest.yaml"
CONTAINER_IMAGE="ghcr.io/flathub-infra/flatpak-github-actions:gnome-49"

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

echo "==> Pushing to local registry..."
skopeo copy \
  --dest-tls-verify=false \
  --digestfile "/tmp/${APP}-digest.txt" \
  "oci:./${OCI_DIR}" \
  "docker://${REGISTRY}/castrojo/jorgehub/${APP}:latest"

DIGEST=$(cat "/tmp/${APP}-digest.txt")
echo "==> Digest: ${DIGEST}"

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
echo "==> Done. Image: ${REGISTRY}/castrojo/jorgehub/${APP}:latest"
