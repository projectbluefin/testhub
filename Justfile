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
    RELEASE_DESC="flatpaks/${APP}/release.yaml"
    MANIFEST="flatpaks/${APP}/manifest.yaml"
    ARCH=$(uname -m)
    OCI_DIR=".${APP}.oci"

    if [[ -f "${RELEASE_DESC}" ]]; then
        # === Bundle repack path (e.g. goose) ===
        # Download upstream .flatpak, verify sha256, import into OSTree, export as OCI
        echo "==> mode: bundle-repack (release.yaml)"
        APP_ID=$(yq '.app-id' "${RELEASE_DESC}")
        VERSION=$(yq '.version' "${RELEASE_DESC}")
        URL=$(yq '.url' "${RELEASE_DESC}")
        EXPECTED_SHA=$(yq '.sha256' "${RELEASE_DESC}")
        [[ -n "${APP_ID}" && -n "${VERSION}" && -n "${URL}" && -n "${EXPECTED_SHA}" ]] \
          || { echo "ERROR: release.yaml missing required fields" >&2; exit 1; }
        REF="app/${APP_ID}/${ARCH}/stable"
        echo "==> Downloading ${URL}"
        BUNDLE_FILE="/tmp/${APP}-${VERSION}.flatpak"
        curl -fsSL -o "${BUNDLE_FILE}" "${URL}"
        ACTUAL_SHA=$(sha256sum "${BUNDLE_FILE}" | cut -d' ' -f1)
        if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
            echo "ERROR: sha256 mismatch" >&2
            echo "  expected: ${EXPECTED_SHA}" >&2
            echo "  actual:   ${ACTUAL_SHA}" >&2
            exit 1
        fi
        echo "==> sha256 OK: ${ACTUAL_SHA}"
        echo "==> Importing bundle into OSTree repo"
        podman image exists "{{container_image}}" || podman pull "{{container_image}}"
        # Init repo if it doesn't exist — flatpak-builder creates it automatically,
        # but build-import-bundle requires it to already exist
        [[ -d ".ostree-repo" ]] || podman run --rm --privileged \
          -v "$(pwd):/workspace:z" -w /workspace \
          "{{container_image}}" \
          ostree init --mode=archive-z2 --repo=.ostree-repo
        # --ref: override the embedded ref name so it matches our standard REF
        podman run --rm --privileged \
          -v "$(pwd):/workspace:z" \
          -v "${BUNDLE_FILE}:${BUNDLE_FILE}:z" \
          -w /workspace \
          -e SOURCE_DATE_EPOCH=0 \
          "{{container_image}}" \
          flatpak build-import-bundle --ref="${REF}" .ostree-repo "${BUNDLE_FILE}"
        echo "==> Exporting OCI bundle"
        rm -rf "${OCI_DIR}"
        podman run --rm --privileged \
          -v "$(pwd):/workspace:z" -w /workspace \
          -e SOURCE_DATE_EPOCH=0 \
          "{{container_image}}" \
          flatpak build-bundle --oci .ostree-repo "${OCI_DIR}" "${REF}"
    elif [[ -f "${MANIFEST}" ]]; then
        # === flatpak-builder path (e.g. ghostty) ===
        echo "==> mode: flatpak-builder (manifest.yaml)"
        APP_ID=$(yq '.app-id' "${MANIFEST}")
        [[ -n "${APP_ID}" ]] || { echo "ERROR: could not determine app-id from ${MANIFEST}" >&2; exit 1; }
        REF="app/${APP_ID}/${ARCH}/stable"
        echo "==> Building ${REF}"
        echo "==> mode: full (ghcr.io push)"
        podman image exists "{{container_image}}" || podman pull "{{container_image}}"
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
    else
        echo "ERROR: no manifest.yaml or release.yaml found in flatpaks/${APP}/" >&2
        exit 1
    fi

    # === Common: push to local registry for label verification ===
    skopeo copy --dest-tls-verify=false \
      --digestfile "/tmp/${APP}-digest.txt" \
      "oci:./${OCI_DIR}" \
      "docker://{{local_registry}}/castrojo/jorgehub/${APP}:latest"
    DIGEST=$(cat "/tmp/${APP}-digest.txt")
    echo "==> Local digest: ${DIGEST}"
    skopeo inspect --tls-verify=false \
      "docker://{{local_registry}}/castrojo/jorgehub/${APP}@${DIGEST}" \
      | jq -e '
        .Labels["org.flatpak.ref"] // error("MISSING: org.flatpak.ref"),
        .Labels["org.flatpak.metadata"] // error("MISSING: org.flatpak.metadata")
        | "OK: " + (if type == "string" then "present" else "present" end)
      ' > /dev/null \
      && echo "All required labels present." \
      || { echo "ERROR: required labels missing" >&2; exit 1; }
    # Load OCI into podman image store (--quiet: output image ID only, no progress noise)
    IMAGE_ID=$(podman pull --quiet "oci:./${OCI_DIR}")
    echo "==> Image ID: ${IMAGE_ID}"
    gh auth token | podman login ghcr.io --username castrojo --password-stdin
    podman push --compression-format=zstd:chunked \
      --digestfile "/tmp/${APP}-ghcr-digest.txt" \
      "${IMAGE_ID}" "docker://ghcr.io/castrojo/${APP}:latest-${ARCH}"
    GHCR_DIGEST=$(cat "/tmp/${APP}-ghcr-digest.txt")
    echo "==> ghcr.io digest: ${GHCR_DIGEST}"
    # Verify zstd:chunked
    skopeo inspect --raw "docker://ghcr.io/castrojo/${APP}:latest-${ARCH}" \
      | jq -r '.layers[] | "Layer: \(.mediaType)  zstd=\(.mediaType | contains("zstd"))  chunked=\(.annotations["io.github.containers.zstd-chunked.manifest"] != null)"'
    echo "==> Done. ghcr.io/castrojo/${APP}:latest-${ARCH} @ ${GHCR_DIGEST}"

# Loop: build + local registry only (no ghcr push) — dev iteration target
loop app="ghostty":
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{app}}"
    RELEASE_DESC="flatpaks/${APP}/release.yaml"
    MANIFEST="flatpaks/${APP}/manifest.yaml"
    ARCH=$(uname -m)
    OCI_DIR=".${APP}.oci"

    if [[ -f "${RELEASE_DESC}" ]]; then
        # === Bundle repack path (e.g. goose) ===
        echo "==> mode: bundle-repack LOCAL_ONLY"
        APP_ID=$(yq '.app-id' "${RELEASE_DESC}")
        VERSION=$(yq '.version' "${RELEASE_DESC}")
        URL=$(yq '.url' "${RELEASE_DESC}")
        EXPECTED_SHA=$(yq '.sha256' "${RELEASE_DESC}")
        [[ -n "${APP_ID}" && -n "${VERSION}" && -n "${URL}" && -n "${EXPECTED_SHA}" ]] \
          || { echo "ERROR: release.yaml missing required fields" >&2; exit 1; }
        REF="app/${APP_ID}/${ARCH}/stable"
        BUNDLE_FILE="/tmp/${APP}-${VERSION}.flatpak"
        # Reuse cached download if sha256 already verified
        if [[ -f "${BUNDLE_FILE}" ]]; then
            CACHED_SHA=$(sha256sum "${BUNDLE_FILE}" | cut -d' ' -f1)
            if [[ "${CACHED_SHA}" == "${EXPECTED_SHA}" ]]; then
                echo "==> Using cached bundle: ${BUNDLE_FILE}"
            else
                echo "==> Cached bundle sha256 mismatch, re-downloading"
                curl -fsSL -o "${BUNDLE_FILE}" "${URL}"
            fi
        else
            echo "==> Downloading ${URL}"
            curl -fsSL -o "${BUNDLE_FILE}" "${URL}"
        fi
        ACTUAL_SHA=$(sha256sum "${BUNDLE_FILE}" | cut -d' ' -f1)
        if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
            echo "ERROR: sha256 mismatch" >&2
            echo "  expected: ${EXPECTED_SHA}" >&2
            echo "  actual:   ${ACTUAL_SHA}" >&2
            exit 1
        fi
        echo "==> sha256 OK: ${ACTUAL_SHA}"
        echo "==> Importing bundle into OSTree repo"
        podman image exists "{{container_image}}" || podman pull "{{container_image}}"
        [[ -d ".ostree-repo" ]] || podman run --rm --privileged \
          -v "$(pwd):/workspace:z" -w /workspace \
          "{{container_image}}" \
          ostree init --mode=archive-z2 --repo=.ostree-repo
        podman run --rm --privileged \
          -v "$(pwd):/workspace:z" \
          -v "${BUNDLE_FILE}:${BUNDLE_FILE}:z" \
          -w /workspace \
          -e SOURCE_DATE_EPOCH=0 \
          "{{container_image}}" \
          flatpak build-import-bundle --ref="${REF}" .ostree-repo "${BUNDLE_FILE}"
        echo "==> Exporting OCI bundle"
        rm -rf "${OCI_DIR}"
        podman run --rm --privileged \
          -v "$(pwd):/workspace:z" -w /workspace \
          -e SOURCE_DATE_EPOCH=0 \
          "{{container_image}}" \
          flatpak build-bundle --oci .ostree-repo "${OCI_DIR}" "${REF}"
    elif [[ -f "${MANIFEST}" ]]; then
        # === flatpak-builder path (e.g. ghostty) ===
        echo "==> mode: flatpak-builder LOCAL_ONLY"
        APP_ID=$(yq '.app-id' "${MANIFEST}")
        [[ -n "${APP_ID}" ]] || { echo "ERROR: could not determine app-id from ${MANIFEST}" >&2; exit 1; }
        REF="app/${APP_ID}/${ARCH}/stable"
        echo "==> Building ${REF}"
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
    else
        echo "ERROR: no manifest.yaml or release.yaml found in flatpaks/${APP}/" >&2
        exit 1
    fi

    # === Common: chunkah rechunk → local registry ===
    # 1. Load OCI dir into podman image store
    IMAGE_ID=$(podman pull --quiet "oci:./${OCI_DIR}")
    echo "==> Loaded image: ${IMAGE_ID}"

    # 2. Ensure chunkah image is cached
    podman image exists "quay.io/jlebon/chunkah:v0.2.0" || podman pull "quay.io/jlebon/chunkah:v0.2.0"

    # 3. Capture container config for chunkah (export before assign for set -euo pipefail)
    export CHUNKAH_CONFIG_STR
    CHUNKAH_CONFIG_STR=$(podman inspect "${IMAGE_ID}" | jq -c '.[0]')

    # 4. Run chunkah via image-mount — outputs uncompressed OCI archive to stdout
    podman run --rm \
      --mount=type=image,src="${IMAGE_ID}",dest=/chunkah \
      -e CHUNKAH_CONFIG_STR \
      quay.io/jlebon/chunkah:v0.2.0 build \
      > "/tmp/${APP}-chunked.ociarchive"

    # 5. Load chunked archive — anchor grep to "Loaded image:" line (not blob sha)
    CHUNKED_ID=$(podman load < "/tmp/${APP}-chunked.ociarchive" | grep 'Loaded image:' | grep -oP '(?<=sha256:)[a-f0-9]+')
    echo "==> Chunked image: sha256:${CHUNKED_ID}"

    # 6. Verify labels survived chunkah round-trip
    podman inspect "${CHUNKED_ID}" \
      | jq -e '.[0].Config.Labels["org.flatpak.ref"] // error("MISSING: org.flatpak.ref")' \
      > /dev/null && echo "==> Labels OK"

    # 7. Report layer count
    LAYER_COUNT=$(podman inspect "${CHUNKED_ID}" | jq '.[0].RootFS.Layers | length')
    echo "==> Layer count: ${LAYER_COUNT}"

    # 8. Push chunked image to local registry
    skopeo copy --dest-tls-verify=false \
      --digestfile "/tmp/${APP}-digest.txt" \
      "containers-storage:${CHUNKED_ID}" \
      "docker://{{local_registry}}/castrojo/jorgehub/${APP}:latest"

    # 9. Verify labels in local registry
    DIGEST=$(cat "/tmp/${APP}-digest.txt")
    skopeo inspect --tls-verify=false \
      "docker://{{local_registry}}/castrojo/jorgehub/${APP}@${DIGEST}" \
      | jq -e '
        .Labels["org.flatpak.ref"] // error("MISSING: org.flatpak.ref"),
        .Labels["org.flatpak.metadata"] // error("MISSING: org.flatpak.metadata")
        | "OK: present"
      ' > /dev/null && echo "All required labels present."
    echo "==> LOCAL_ONLY done. ${DIGEST} — layers: ${LAYER_COUNT}"

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
