set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    just --list

# === Configuration ===
container_image := "ghcr.io/flathub-infra/flatpak-github-actions:gnome-49"
local_registry := "localhost:5000"

# === Private helpers ===

# Apply OCI standard labels to an image before chunkah processing.
# Arguments: image-id version url release-desc
# version and url may be empty (flatpak-builder path); release-desc may be absent.
_apply-oci-labels image-id version="" url="" release-desc="":
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE_ID="{{image-id}}"
    VERSION="{{version}}"
    URL="{{url}}"
    RELEASE_DESC="{{release-desc}}"
    CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    GH_OWNER="${GITHUB_REPOSITORY_OWNER:-castrojo}"
    # buildah config operates on working containers, not image IDs.
    # Pattern: from → config → commit → rm; output new image ID on stdout for caller to capture.
    CTR=$(buildah from "${IMAGE_ID}")
    echo "==> buildah container: ${CTR}" >&2
    buildah config \
      --label "org.opencontainers.image.version=${VERSION}" \
      --label "org.opencontainers.image.source=${URL}" \
      --label "org.opencontainers.image.created=${CREATED}" \
      --label "org.opencontainers.image.vendor=${GH_OWNER}" \
      --label "org.opencontainers.image.url=https://github.com/${GH_OWNER}/jorgehub" \
      "${CTR}"
    if [[ -n "${VERSION}" && -f "${RELEASE_DESC}" ]]; then
        TITLE=$(yq '.title // ""' "${RELEASE_DESC}")
        DESCRIPTION=$(yq '.description // ""' "${RELEASE_DESC}")
        LICENSE=$(yq '.license // ""' "${RELEASE_DESC}")
        labels=()
        [[ -n "${TITLE}" ]]       && labels+=(--label "org.opencontainers.image.title=${TITLE}")
        [[ -n "${DESCRIPTION}" ]] && labels+=(--label "org.opencontainers.image.description=${DESCRIPTION}")
        [[ -n "${LICENSE}" ]]     && labels+=(--label "org.opencontainers.image.licenses=${LICENSE}")
        (( ${#labels[@]} > 0 )) && buildah config "${labels[@]}" "${CTR}"
    fi
    NEW_ID=$(buildah commit "${CTR}")
    buildah rm "${CTR}" > /dev/null
    echo "==> OCI labels applied → ${NEW_ID}" >&2
    echo "${NEW_ID}"

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
        BRANCH=$(yq '.default-branch // "stable"' "${MANIFEST}")
        REF="app/${APP_ID}/${ARCH}/${BRANCH}"
        VERSION=$(yq '.x-version // ""' "${MANIFEST}")
        [[ -n "${VERSION}" && "${VERSION}" != "null" ]] \
          && echo "==> Flatpak-builder: VERSION=${VERSION}" \
          || { echo "==> Flatpak-builder: no x-version in manifest.yaml — :latest only"; VERSION=""; }
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

    # === Common: load into podman, run chunkah, verify, push ===
    IMAGE_ID=$(podman pull --quiet "oci:./${OCI_DIR}")
    echo "==> Single-layer image: ${IMAGE_ID}"
    # Apply OCI standard labels before chunkah — labels added after CHUNKAH_CONFIG_STR is captured are lost
    IMAGE_ID=$(just _apply-oci-labels "${IMAGE_ID}" "${VERSION:-}" "${URL:-}" "${RELEASE_DESC}")
    echo "==> Running chunkah to split into content-based layers"
    podman image exists "quay.io/jlebon/chunkah:v0.2.0" || podman pull "quay.io/jlebon/chunkah:v0.2.0"
    export CHUNKAH_CONFIG_STR
    CHUNKAH_CONFIG_STR=$(podman inspect "${IMAGE_ID}" | jq -c '.[0]')
    podman run --rm \
      --mount=type=image,src="${IMAGE_ID}",dest=/chunkah \
      -e CHUNKAH_CONFIG_STR \
      quay.io/jlebon/chunkah:v0.2.0 build \
      > "/tmp/${APP}-chunked.ociarchive"
    echo "==> Loading chunked OCI archive"
    CHUNKED_ID=$(podman load < "/tmp/${APP}-chunked.ociarchive" | grep 'Loaded image:' | grep -oP '(?<=sha256:)[a-f0-9]+')
    echo "==> Chunked image: ${CHUNKED_ID}"
    # Verify labels survived chunkah
    podman inspect "${CHUNKED_ID}" \
      | jq -e '.[0].Config.Labels["org.flatpak.ref"] // error("MISSING: org.flatpak.ref")' \
      > /dev/null && echo "==> Flatpak labels OK"
    LAYER_COUNT=$(podman inspect "${CHUNKED_ID}" | jq '.[0].RootFS.Layers | length')
    echo "==> Layer count after chunkah: ${LAYER_COUNT}"
    # Push to local registry for label verification
    skopeo copy --dest-tls-verify=false \
      --digestfile "/tmp/${APP}-local-digest.txt" \
      "containers-storage:${CHUNKED_ID}" \
      "docker://localhost:5000/castrojo/jorgehub/${APP}:latest"
    LOCAL_DIGEST=$(cat "/tmp/${APP}-local-digest.txt")
    echo "==> Local digest: ${LOCAL_DIGEST}"
    skopeo inspect --tls-verify=false \
      "docker://localhost:5000/castrojo/jorgehub/${APP}@${LOCAL_DIGEST}" \
      | jq -e '
        .Labels["org.flatpak.ref"] // error("MISSING: org.flatpak.ref"),
        .Labels["org.flatpak.metadata"] // error("MISSING: org.flatpak.metadata"),
        .Labels["org.opencontainers.image.created"] // error("MISSING: org.opencontainers.image.created")
        | "OK: present"
      ' > /dev/null \
      && echo "All required labels present."
    # Push to ghcr.io with zstd:chunked
    GH_OWNER="${GITHUB_REPOSITORY_OWNER:-castrojo}"
    gh auth token | podman login ghcr.io --username "${GH_OWNER}" --password-stdin
    podman push --compression-format=zstd:chunked \
      --digestfile "/tmp/${APP}-ghcr-digest.txt" \
      "${CHUNKED_ID}" "docker://ghcr.io/${GH_OWNER}/${APP}:latest-${ARCH}"
    GHCR_DIGEST=$(cat "/tmp/${APP}-ghcr-digest.txt")
    echo "==> ghcr.io digest: ${GHCR_DIGEST}"
    # Version and stable tags — set for bundle-repack; for manifest.yaml apps, requires x-version field
    if [[ -n "${VERSION:-}" ]]; then
        echo "==> Pushing version tag: ${VERSION}-${ARCH}"
        skopeo copy --compression-format=zstd:chunked --dest-creds "${GH_OWNER}:$(gh auth token)" \
          "containers-storage:${CHUNKED_ID}" \
          "docker://ghcr.io/${GH_OWNER}/${APP}:${VERSION}-${ARCH}"
        echo "==> Pushing stable tag"
        skopeo copy --compression-format=zstd:chunked --dest-creds "${GH_OWNER}:$(gh auth token)" \
          "containers-storage:${CHUNKED_ID}" \
          "docker://ghcr.io/${GH_OWNER}/${APP}:stable-${ARCH}"
        echo "==> Tags pushed: latest-${ARCH}, ${VERSION}-${ARCH}, stable-${ARCH}"
    fi
    # Verify ALL layers are zstd:chunked — fail if any are not
    LAYER_RESULTS=$(skopeo inspect --raw "docker://ghcr.io/${GH_OWNER}/${APP}:latest-${ARCH}" \
      | jq -r '.layers[] | "Layer \(.digest[:19]): mediaType=\(.mediaType) chunked=\((.annotations // {}) | has("io.github.containers.zstd-chunked.manifest-checksum"))"')
    echo "${LAYER_RESULTS}"
    if echo "${LAYER_RESULTS}" | grep -q "chunked=false"; then
      echo "ERROR: one or more layers missing zstd:chunked annotation" >&2
      exit 1
    fi
    echo "==> All ${LAYER_COUNT} layers are zstd:chunked"
    echo "==> Done. ghcr.io/${GH_OWNER}/${APP}:latest-${ARCH} @ ${GHCR_DIGEST}"

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
        BRANCH=$(yq '.default-branch // "stable"' "${MANIFEST}")
        REF="app/${APP_ID}/${ARCH}/${BRANCH}"
        VERSION=$(yq '.x-version // ""' "${MANIFEST}")
        [[ -n "${VERSION}" && "${VERSION}" != "null" ]] \
          && echo "==> Flatpak-builder: VERSION=${VERSION}" \
          || { echo "==> Flatpak-builder: no x-version in manifest.yaml — :latest only"; VERSION=""; }
        echo "==> Building ${REF}"
        podman image exists "{{container_image}}" || podman pull "{{container_image}}"
        podman run --rm --privileged \
          -v "$(pwd):/workspace:z" -w /workspace \
          -e SOURCE_DATE_EPOCH=0 \
          "{{container_image}}" \
          flatpak-builder \
            --disable-rofiles-fuse --force-clean \
            --override-source-date-epoch=0 \
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

    # 1b. Apply OCI standard labels before chunkah — labels added after CHUNKAH_CONFIG_STR are lost
    IMAGE_ID=$(just _apply-oci-labels "${IMAGE_ID}" "${VERSION:-}" "${URL:-}" "${RELEASE_DESC}")

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
        .Labels["org.flatpak.metadata"] // error("MISSING: org.flatpak.metadata"),
        .Labels["org.opencontainers.image.created"] // error("MISSING: org.opencontainers.image.created")
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
      --repo "castrojo/{{app}}" \
      --digest "${DIGEST}" \
      --registry ghcr.io \
      --tags "latest-${ARCH}"
    git -C /tmp/jorgehub-pages add index/static
    git -C /tmp/jorgehub-pages diff --cached --quiet && echo "index unchanged, skipping commit" || \
      git -C /tmp/jorgehub-pages commit -m "feat(index): update {{app}} to ${DIGEST:0:19}"
    git -C /tmp/jorgehub-pages push origin gh-pages
    git worktree remove /tmp/jorgehub-pages --force

# Validate index/static JSON is well-formed (must run from gh-pages checkout)
check-index:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    git worktree add /tmp/jorgehub-pages gh-pages 2>/dev/null || true
    cd /tmp/jorgehub-pages && python3 "${REPO_ROOT}/scripts/update-index.py" --validate
    git worktree remove /tmp/jorgehub-pages --force

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
