set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    just --list

# === Configuration ===
container_image := "ghcr.io/flathub-infra/flatpak-github-actions:gnome-49"
local_registry := "localhost:5000"
chunkah_image := "quay.io/jlebon/chunkah:v0.3.0"

# === Tool bootstrap ===

# Install yq for metadata parsing (CI bootstrap — local dev typically has yq already)
install-tools-yq:
    #!/usr/bin/env bash
    set -euo pipefail
    YQ_VERSION="v4.52.4"
    if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q "$YQ_VERSION"; then
        echo "yq $YQ_VERSION already installed"
        exit 0
    fi
    echo "Installing yq $YQ_VERSION..."
    case "$(uname -m)" in
      aarch64) YQ_ARCH="arm64" ;;
      *)       YQ_ARCH="amd64" ;;
    esac
    wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}"
    chmod +x /usr/local/bin/yq
    yq --version

# Install podman via Homebrew (CI bootstrap for bare ubuntu-24.04 runners)
install-tools-podman:
    #!/usr/bin/env bash
    set -euo pipefail
    BREW="/home/linuxbrew/.linuxbrew/bin/brew"
    export PATH="/home/linuxbrew/.linuxbrew/bin:${PATH}"
    if "${BREW}" list podman &>/dev/null; then
        echo "podman already installed via brew"
        exit 0
    fi
    echo "Installing podman via Homebrew..."
    "${BREW}" install podman
    mkdir -p ~/.config/containers
    printf '[engine]\n  runtime = "crun"\n' > ~/.config/containers/containers.conf
    # Enable unprivileged user namespaces (CI requirement)
    if test -f /proc/sys/kernel/unprivileged_userns_clone; then
        sysctl kernel.unprivileged_userns_clone=1 || true
    fi
    podman --version

# Install oras for manifest index operations (CI bootstrap)
install-tools-oras:
    #!/usr/bin/env bash
    set -euo pipefail
    ORAS_VERSION="1.3.1"
    if command -v oras >/dev/null 2>&1 && oras version 2>&1 | grep -q "$ORAS_VERSION"; then
        echo "oras $ORAS_VERSION already installed"
        exit 0
    fi
    echo "Installing oras $ORAS_VERSION..."
    case "$(uname -m)" in
      aarch64) ORAS_ARCH="arm64" ;;
      *)       ORAS_ARCH="amd64" ;;
    esac
    wget -qO /tmp/oras.tar.gz "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${ORAS_ARCH}.tar.gz"
    tar -xzf /tmp/oras.tar.gz -C /usr/local/bin oras
    chmod +x /usr/local/bin/oras
    oras version

# Install all CI tools (yq, podman, oras)
install-tools: install-tools-yq install-tools-podman install-tools-oras

# === Metadata helpers ===

# Read a metadata key for an app. Usage: just metadata APP KEY
# Handles both release.yaml and manifest.yaml with x-prefix variants.
metadata app key:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app }}"
    KEY="{{ key }}"

    # Look in flatpaks/<APP>/ — support both app-id-based dirs and short names
    # First try exact directory match, then search by app-id
    if test -d "flatpaks/$APP"; then
        DIR="flatpaks/$APP"
    else
        # Search for a dir containing the app-id
        DIR=$(find flatpaks -maxdepth 2 \( -name "manifest.yaml" -o -name "release.yaml" \) -exec grep -l "app-id: $APP" {} \; | head -1 | xargs dirname 2>/dev/null || echo "")
        if test -z "$DIR"; then
            echo ""
            exit 0
        fi
    fi

    if test -f "$DIR/release.yaml"; then
        FILE="$DIR/release.yaml"
    elif test -f "$DIR/manifest.yaml"; then
        FILE="$DIR/manifest.yaml"
    else
        echo ""
        exit 0
    fi

    # Try x-KEY first, then KEY (handles both manifest.yaml x-prefix and release.yaml no-prefix)
    VALUE=$(yq e ".x-${KEY} // .${KEY} // \"\"" "$FILE" 2>/dev/null | head -1 || echo "")
    echo "${VALUE}"

# Check if an arch should be skipped for an app. Prints 'true' to skip, 'false' to build.
# Usage: just _skip-arch APP ARCH
_skip-arch app arch:
    #!/usr/bin/env bash
    set -euo pipefail
    ARCHES=$(just metadata "{{ app }}" arches 2>/dev/null || echo "")
    if test -z "$ARCHES"; then
        # No arch restriction — build on all arches
        echo "false"
        exit 0
    fi
    # Normalize: strip brackets, quotes, and whitespace; split on comma/space
    ARCH="{{ arch }}"
    if echo "$ARCHES" | tr ',[]\n' ' ' | tr -s ' ' | grep -qw "$ARCH"; then
        echo "false"
    else
        echo "true"
    fi

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
    GH_OWNER="${GITHUB_REPOSITORY_OWNER:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*\)/.*|\1|')}"
    GH_REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*/[^/.]*\).*|\1|')}"
    # buildah config operates on working containers, not image IDs.
    # Pattern: from → config → commit → rm; output new image ID on stdout for caller to capture.
    CTR=$(buildah from "${IMAGE_ID}")
    echo "==> buildah container: ${CTR}" >&2
    buildah config \
      --label "org.opencontainers.image.version=${VERSION}" \
      --label "org.opencontainers.image.source=${URL}" \
      --label "org.opencontainers.image.created=${CREATED}" \
      --label "org.opencontainers.image.vendor=${GH_OWNER}" \
      --label "org.opencontainers.image.url=https://github.com/${GH_REPO}" \
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

# === Build engine helpers ===

# Bundle-repack path: download upstream .flatpak, verify sha256, export OCI to .APP.oci/
# Output: prints OCI_DIR path on stdout. Sets SOURCE_DATE_EPOCH=0 for determinism.
# NOTE: APP may be a short dir name (goose) or full app-id — metadata helper resolves both.
_repack app arch:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app }}"
    ARCH="{{ arch }}"

    # Arch gate
    SKIP=$(just _skip-arch "${APP}" "${ARCH}")
    if [[ "${SKIP}" == "true" ]]; then
        echo "==> SKIP: ${APP} does not build on ${ARCH}" >&2
        echo "SKIP"
        exit 0
    fi

    # Locate the release.yaml file
    if test -d "flatpaks/${APP}"; then
        RELEASE_DESC="flatpaks/${APP}/release.yaml"
    else
        RELEASE_DESC=$(find flatpaks -maxdepth 2 -name "release.yaml" -exec grep -l "app-id: ${APP}" {} \; | head -1 || echo "")
    fi
    if [[ ! -f "${RELEASE_DESC:-}" ]]; then
        echo "ERROR: no release.yaml found for ${APP}" >&2
        exit 1
    fi

    APP_ID=$(yq '.app-id' "${RELEASE_DESC}")
    VERSION=$(yq '.version' "${RELEASE_DESC}")
    URL=$(yq '.url' "${RELEASE_DESC}")
    EXPECTED_SHA=$(yq '.sha256' "${RELEASE_DESC}")
    [[ -n "${APP_ID}" && -n "${VERSION}" && -n "${URL}" && -n "${EXPECTED_SHA}" ]] \
      || { echo "ERROR: release.yaml missing required fields" >&2; exit 1; }

    REF="app/${APP_ID}/${ARCH}/stable"
    OCI_DIR=".${APP}.oci"
    OSTREE_REPO=".${APP}-ostree-repo"
    BUNDLE_FILE="/tmp/${APP}-${VERSION}.flatpak"

    echo "==> mode: bundle-repack (release.yaml)" >&2

    # Reuse cached bundle if sha256 already verified
    if [[ -f "${BUNDLE_FILE}" ]]; then
        CACHED_SHA=$(sha256sum "${BUNDLE_FILE}" | cut -d' ' -f1)
        if [[ "${CACHED_SHA}" == "${EXPECTED_SHA}" ]]; then
            echo "==> Using cached bundle: ${BUNDLE_FILE}" >&2
        else
            echo "==> Cached sha256 mismatch, re-downloading" >&2
            curl -fsSL -o "${BUNDLE_FILE}" "${URL}"
        fi
    else
        echo "==> Downloading ${URL}" >&2
        curl -fsSL -o "${BUNDLE_FILE}" "${URL}"
    fi

    ACTUAL_SHA=$(sha256sum "${BUNDLE_FILE}" | cut -d' ' -f1)
    if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
        echo "ERROR: sha256 mismatch" >&2
        echo "  expected: ${EXPECTED_SHA}" >&2
        echo "  actual:   ${ACTUAL_SHA}" >&2
        exit 1
    fi
    echo "==> sha256 OK: ${ACTUAL_SHA}" >&2

    # Import bundle into OSTree repo, then export as OCI — runs on host (no container needed)
    rm -rf "${OSTREE_REPO}" "${OCI_DIR}"
    ostree init --mode=archive-z2 --repo="${OSTREE_REPO}"
    echo "==> Importing ${BUNDLE_FILE} → OSTree ref ${REF}" >&2
    flatpak build-import-bundle --ref="${REF}" "${OSTREE_REPO}" "${BUNDLE_FILE}" >&2
    echo "==> Exporting OCI bundle" >&2
    SOURCE_DATE_EPOCH=0 flatpak build-bundle --oci --arch="${ARCH}" "${OSTREE_REPO}" "${OCI_DIR}" "${APP_ID}" stable >&2
    echo "==> OCI bundle: ${OCI_DIR}" >&2
    echo "${OCI_DIR}"

# Flatpak-builder path: build from source in gnome-49, export OCI to .APP.oci/
# LOCAL DEV ONLY — uses direct flatpak-builder (no ccache, no actions/cache).
# CI continues using the flatpak/flatpak-github-actions v6 action for its caching benefits.
_compile app arch:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app }}"
    ARCH="{{ arch }}"

    # Arch gate
    SKIP=$(just _skip-arch "${APP}" "${ARCH}")
    if [[ "${SKIP}" == "true" ]]; then
        echo "==> SKIP: ${APP} does not build on ${ARCH}" >&2
        echo "SKIP"
        exit 0
    fi

    # Batch-read all metadata upfront
    CONTAINER_IMAGE=$(just metadata "${APP}" container-image 2>/dev/null || echo "")
    [[ -z "${CONTAINER_IMAGE}" || "${CONTAINER_IMAGE}" == "null" ]] && CONTAINER_IMAGE="{{ container_image }}"

    # Locate manifest.yaml
    if test -d "flatpaks/${APP}"; then
        MANIFEST="flatpaks/${APP}/manifest.yaml"
    else
        MANIFEST=$(find flatpaks -maxdepth 2 -name "manifest.yaml" -exec grep -l "app-id: ${APP}" {} \; | head -1 || echo "")
    fi
    if [[ ! -f "${MANIFEST:-}" ]]; then
        echo "ERROR: no manifest.yaml found for ${APP}" >&2
        exit 1
    fi

    APP_ID=$(yq '.app-id' "${MANIFEST}")
    [[ -n "${APP_ID}" ]] || { echo "ERROR: could not determine app-id from ${MANIFEST}" >&2; exit 1; }
    BRANCH=$(yq '.default-branch // "stable"' "${MANIFEST}")
    REF="app/${APP_ID}/${ARCH}/${BRANCH}"
    VERSION=$(yq '.x-version // ""' "${MANIFEST}")
    [[ -n "${VERSION}" && "${VERSION}" != "null" ]] \
      && echo "==> VERSION=${VERSION}" >&2 \
      || { echo "==> no x-version — :latest only" >&2; VERSION=""; }

    OCI_DIR=".${APP}.oci"
    OSTREE_REPO=".${APP}-ostree-repo"
    REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

    echo "==> Container image: ${CONTAINER_IMAGE}" >&2
    echo "==> mode: flatpak-builder LOCAL_ONLY (no ccache — CI uses v6 action for caching)" >&2
    echo "==> Building ${REF}" >&2

    podman image exists "${CONTAINER_IMAGE}" || podman pull "${CONTAINER_IMAGE}" >&2
    podman run --rm --privileged --name "${REPO_NAME}-${APP}-build" \
      -v "$(pwd):/workspace:z" -w /workspace \
      -e SOURCE_DATE_EPOCH=0 \
      "${CONTAINER_IMAGE}" \
      flatpak-builder \
        --disable-rofiles-fuse --force-clean \
        --override-source-date-epoch=0 \
        --repo="${OSTREE_REPO}" \
        ".${APP}-build-dir" "${MANIFEST}" >&2
    rm -rf "${OCI_DIR}"
    podman run --rm --privileged --name "${REPO_NAME}-${APP}-bundle" \
      -v "$(pwd):/workspace:z" -w /workspace \
      -e SOURCE_DATE_EPOCH=0 \
      "${CONTAINER_IMAGE}" \
      flatpak build-bundle --oci "${OSTREE_REPO}" "${OCI_DIR}" "${REF}" >&2
    echo "==> OCI bundle: ${OCI_DIR}" >&2
    echo "${OCI_DIR}"

# OCI post-build pipeline: load .APP.oci, apply labels, rechunk, verify — returns final image ID
# Input: .APP.oci directory must exist (produced by _repack or _compile)
# Output: prints final chunked image ID (sha256:...) on stdout; all other output to stderr
_process-oci app arch:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app }}"
    ARCH="{{ arch }}"
    OCI_DIR=".${APP}.oci"

    if [[ ! -d "${OCI_DIR}" ]]; then
        echo "ERROR: ${OCI_DIR} not found — run _repack or _compile first" >&2
        exit 1
    fi

    # Batch-read all metadata upfront
    RELEASE_DESC="flatpaks/${APP}/release.yaml"
    MANIFEST="flatpaks/${APP}/manifest.yaml"
    if [[ -f "${RELEASE_DESC}" ]]; then
        VERSION=$(yq '.version' "${RELEASE_DESC}")
        URL=$(yq '.url' "${RELEASE_DESC}")
        MAX_LAYERS=$(yq '.["chunkah-max-layers"] // 16' "${RELEASE_DESC}")
    else
        VERSION=$(just metadata "${APP}" version 2>/dev/null || echo "")
        [[ "${VERSION}" == "null" ]] && VERSION=""
        URL=""
        MAX_LAYERS=$(yq '.["x-chunkah-max-layers"] // 16' "${MANIFEST}")
    fi
    SKIP_CHUNKAH=$(just metadata "${APP}" skip-chunkah 2>/dev/null || echo "")

    # 1. Load OCI dir into podman image store
    IMAGE_ID=$(podman pull --quiet "oci:./${OCI_DIR}")
    echo "==> Loaded image: ${IMAGE_ID}" >&2

    # 2. Apply OCI standard labels via buildah (must happen before chunkah captures config)
    IMAGE_ID=$(just _apply-oci-labels "${IMAGE_ID}" "${VERSION:-}" "${URL:-}" "${RELEASE_DESC}")
    echo "==> Labels applied: ${IMAGE_ID}" >&2

    # 3. Skip chunkah if flag set (apps with no rpmdb and no files >= 1MB, e.g. Kontainer)
    if [[ "${SKIP_CHUNKAH}" == "true" ]]; then
        echo "==> skip-chunkah: true — bypassing chunkah for ${APP}" >&2
        FINAL_ID="${IMAGE_ID}"
    else
        # 4. Ensure chunkah image is cached
        podman image exists "{{chunkah_image}}" || podman pull "{{chunkah_image}}" >&2

        # 5. Capture container config for chunkah
        export CHUNKAH_CONFIG_STR
        CHUNKAH_CONFIG_STR=$(podman inspect "${IMAGE_ID}" | jq -c '.[0]')

        echo "==> chunkah --max-layers ${MAX_LAYERS}" >&2
        podman run --rm \
          --mount=type=image,src="${IMAGE_ID}",dest=/chunkah \
          -e CHUNKAH_CONFIG_STR \
          "{{chunkah_image}}" build \
          --max-layers "${MAX_LAYERS}" \
          > "/tmp/${APP}-chunked.ociarchive"

        # 6. Load chunked archive
        FINAL_ID=$(podman load < "/tmp/${APP}-chunked.ociarchive" | grep 'Loaded image:' | grep -oP '(?<=sha256:)[a-f0-9]+')
        echo "==> Chunked image: sha256:${FINAL_ID}" >&2
    fi

    # 7. Verify labels survived chunkah round-trip
    podman inspect "${FINAL_ID}" \
      | jq -e '.[0].Config.Labels["org.flatpak.ref"] // error("MISSING: org.flatpak.ref")' \
      > /dev/null && echo "==> Labels OK" >&2

    # 8. Report layer count
    LAYER_COUNT=$(podman inspect "${FINAL_ID}" | jq '.[0].RootFS.Layers | length')
    echo "==> Layer count: ${LAYER_COUNT}" >&2

    echo "sha256:${FINAL_ID}"

# === Build recipes ===

# Build app and push to ghcr.io with zstd:chunked compression
build app="ghostty":
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{app}}"
    RELEASE_DESC="flatpaks/${APP}/release.yaml"
    MANIFEST="flatpaks/${APP}/manifest.yaml"
    ARCH=$(uname -m)

    # === Build path: delegate to _repack or _compile ===
    if [[ -f "${RELEASE_DESC}" ]]; then
        OCI_DIR=$(just _repack "${APP}" "${ARCH}")
        [[ "${OCI_DIR}" == "SKIP" ]] && { echo "==> SKIP: arch not supported"; exit 0; }
        VERSION=$(yq '.version' "${RELEASE_DESC}")
        URL=$(yq '.url' "${RELEASE_DESC}")
    elif [[ -f "${MANIFEST}" ]]; then
        OCI_DIR=$(just _compile "${APP}" "${ARCH}")
        [[ "${OCI_DIR}" == "SKIP" ]] && { echo "==> SKIP: arch not supported"; exit 0; }
        VERSION=$(yq '.x-version // ""' "${MANIFEST}")
        [[ "${VERSION}" == "null" ]] && VERSION=""
        URL=""
    else
        echo "ERROR: no manifest.yaml or release.yaml found in flatpaks/${APP}/" >&2
        exit 1
    fi

    # === Common: OCI pipeline → push ===
    GH_OWNER="${GITHUB_REPOSITORY_OWNER:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*\)/.*|\1|')}"
    GH_REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*/[^/.]*\).*|\1|')}"
    CHUNKED_ID=$(just _process-oci "${APP}" "${ARCH}")
    CHUNKED_ID="${CHUNKED_ID#sha256:}"   # skopeo containers-storage: needs bare hash
    LAYER_COUNT=$(podman inspect "${CHUNKED_ID}" | jq '.[0].RootFS.Layers | length')
    # Push to local registry for label verification
    skopeo copy --dest-tls-verify=false \
      --digestfile "/tmp/${APP}-local-digest.txt" \
      "containers-storage:${CHUNKED_ID}" \
      "docker://localhost:5000/${GH_REPO}/${APP}:latest"
    LOCAL_DIGEST=$(cat "/tmp/${APP}-local-digest.txt")
    echo "==> Local digest: ${LOCAL_DIGEST}"
    skopeo inspect --tls-verify=false \
      "docker://localhost:5000/${GH_REPO}/${APP}@${LOCAL_DIGEST}" \
      | jq -e '
        .Labels["org.flatpak.ref"] // error("MISSING: org.flatpak.ref"),
        .Labels["org.flatpak.metadata"] // error("MISSING: org.flatpak.metadata"),
        .Labels["org.opencontainers.image.created"] // error("MISSING: org.opencontainers.image.created")
        | "OK: present"
      ' > /dev/null \
      && echo "All required labels present."
    # Push to ghcr.io with zstd:chunked
    gh auth token | podman login ghcr.io --username "${GH_OWNER}" --password-stdin
    podman push --compression-format=zstd:chunked \
      --digestfile "/tmp/${APP}-ghcr-digest.txt" \
      "${CHUNKED_ID}" "docker://ghcr.io/${GH_REPO}/${APP}:latest-${ARCH}"
    GHCR_DIGEST=$(cat "/tmp/${APP}-ghcr-digest.txt")
    echo "==> ghcr.io digest: ${GHCR_DIGEST}"
    # Version and stable tags — set for bundle-repack; for manifest.yaml apps, requires x-version field
    if [[ -n "${VERSION:-}" ]]; then
        echo "==> Pushing version tag: ${VERSION}-${ARCH}"
        skopeo copy --compression-format=zstd:chunked --dest-creds "${GH_OWNER}:$(gh auth token)" \
          "containers-storage:${CHUNKED_ID}" \
          "docker://ghcr.io/${GH_REPO}/${APP}:${VERSION}-${ARCH}"
        echo "==> Pushing stable tag"
        skopeo copy --compression-format=zstd:chunked --dest-creds "${GH_OWNER}:$(gh auth token)" \
          "containers-storage:${CHUNKED_ID}" \
          "docker://ghcr.io/${GH_REPO}/${APP}:stable-${ARCH}"
        echo "==> Tags pushed: latest-${ARCH}, ${VERSION}-${ARCH}, stable-${ARCH}"
    fi
    # Verify ALL layers are zstd:chunked — fail if any are not
    LAYER_RESULTS=$(skopeo inspect --raw "docker://ghcr.io/${GH_REPO}/${APP}:latest-${ARCH}" \
      | jq -r '.layers[] | "Layer \(.digest[:19]): mediaType=\(.mediaType) chunked=\((.annotations // {}) | has("io.github.containers.zstd-chunked.manifest-checksum"))"')
    echo "${LAYER_RESULTS}"
    if echo "${LAYER_RESULTS}" | grep -q "chunked=false"; then
      echo "ERROR: one or more layers missing zstd:chunked annotation" >&2
      exit 1
    fi
    echo "==> All ${LAYER_COUNT} layers are zstd:chunked"
    echo "==> Done. ghcr.io/${GH_REPO}/${APP}:latest-${ARCH} @ ${GHCR_DIGEST}"

# Loop all apps concurrently — one just loop per app, parallel (preferred for local validation passes)
loop-all:
    #!/usr/bin/env bash
    set -euo pipefail
    APPS=(ghostty goose lmstudio firefox-nightly thunderbird-nightly virtualbox "io.github.DenysMb.Kontainer" "org.altlinux.Tuner")
    echo "==> loop-all: building ${#APPS[@]} apps in parallel"
    pids=()
    for app in "${APPS[@]}"; do
        just loop "${app}" > "/tmp/loop-${app}.log" 2>&1 &
        pids+=("$!:${app}")
        echo "==> Started loop for ${app} (pid $!)"
    done
    failed=()
    for entry in "${pids[@]}"; do
        pid="${entry%%:*}"; app="${entry##*:}"
        if wait "${pid}"; then
            echo "==> OK: ${app}"
        else
            echo "==> FAIL: ${app} — see /tmp/loop-${app}.log"
            failed+=("${app}")
        fi
    done
    for app in "${APPS[@]}"; do
        echo "--- ${app} log ---"
        cat "/tmp/loop-${app}.log"
    done
    (( ${#failed[@]} == 0 )) || { echo "FAILED: ${failed[*]}"; exit 1; }
    echo "==> loop-all done"

# Loop: build + local registry only (no ghcr push) — dev iteration target
loop app="ghostty":
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{app}}"
    RELEASE_DESC="flatpaks/${APP}/release.yaml"
    MANIFEST="flatpaks/${APP}/manifest.yaml"
    ARCH=$(uname -m)

    # === Build path: delegate to _repack or _compile ===
    if [[ -f "${RELEASE_DESC}" ]]; then
        OCI_DIR=$(just _repack "${APP}" "${ARCH}")
        [[ "${OCI_DIR}" == "SKIP" ]] && { echo "==> SKIP: arch not supported"; exit 0; }
        VERSION=$(yq '.version' "${RELEASE_DESC}")
        URL=$(yq '.url' "${RELEASE_DESC}")
    elif [[ -f "${MANIFEST}" ]]; then
        OCI_DIR=$(just _compile "${APP}" "${ARCH}")
        [[ "${OCI_DIR}" == "SKIP" ]] && { echo "==> SKIP: arch not supported"; exit 0; }
        VERSION=$(yq '.x-version // ""' "${MANIFEST}")
        [[ "${VERSION}" == "null" ]] && VERSION=""
        URL=""
    else
        echo "ERROR: no manifest.yaml or release.yaml found in flatpaks/${APP}/" >&2
        exit 1
    fi

    # === Common: OCI pipeline → local registry ===
    GH_REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*/[^/.]*\).*|\1|')}"
    CHUNKED_ID=$(just _process-oci "${APP}" "${ARCH}")
    CHUNKED_ID="${CHUNKED_ID#sha256:}"   # skopeo containers-storage: needs bare hash
    LAYER_COUNT=$(podman inspect "${CHUNKED_ID}" | jq '.[0].RootFS.Layers | length')

    # Push chunked image to local registry
    skopeo copy --dest-tls-verify=false \
      --digestfile "/tmp/${APP}-digest.txt" \
      "containers-storage:${CHUNKED_ID}" \
      "docker://{{local_registry}}/${GH_REPO}/${APP}:latest"

    # 9. Verify labels in local registry
    DIGEST=$(cat "/tmp/${APP}-digest.txt")
    skopeo inspect --tls-verify=false \
      "docker://{{local_registry}}/${GH_REPO}/${APP}@${DIGEST}" \
      | jq -e '
        .Labels["org.flatpak.ref"] // error("MISSING: org.flatpak.ref"),
        .Labels["org.flatpak.metadata"] // error("MISSING: org.flatpak.metadata"),
        .Labels["org.opencontainers.image.created"] // error("MISSING: org.opencontainers.image.created")
        | "OK: present"
      ' > /dev/null && echo "All required labels present."
    echo "==> LOCAL_ONLY done. ${DIGEST} — layers: ${LAYER_COUNT}"

# Push per-arch image to registry with zstd:chunked compression
# Usage: just push APP ARCH [REGISTRY]
# SCOPE: login, podman push, digestfile, version+stable tags.
# CI-only concerns (staging tags, SBOM, attestation, cosign, layer cache, STEP_SUMMARY) stay in YAML.
push app arch registry="ghcr.io":
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app }}"
    ARCH="{{ arch }}"
    REGISTRY="{{ registry }}"
    case "${ARCH}" in
      x86_64|aarch64) ;;
      *) echo "ERROR: unknown arch ${ARCH}" >&2; exit 1 ;;
    esac

    APP_LOWER="${APP,,}"
    GH_OWNER="${GITHUB_REPOSITORY_OWNER:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*\)/.*|\1|')}"
    GH_REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*/[^/.]*\).*|\1|')}"

    # Resolve CHUNKED image ID from containers-storage (built by _process-oci)
    # _process-oci prints sha256:HASH on stdout — strip prefix for podman
    CHUNKED_REF=$(just _process-oci "${APP}" "${ARCH}")
    CHUNKED_ID="${CHUNKED_REF#sha256:}"

    VERSION=$(just metadata "${APP}" version 2>/dev/null || echo "")
    [[ "${VERSION}" == "null" ]] && VERSION=""

    # Login to registry
    if [[ "${REGISTRY}" == "ghcr.io" ]]; then
        gh auth token | podman login ghcr.io --username "${GH_OWNER}" --password-stdin
    fi

    # Push :latest-<arch> with zstd:chunked
    TARGET="${REGISTRY}/${GH_REPO}/${APP_LOWER}:latest-${ARCH}"
    podman push \
        --compression-format=zstd:chunked \
        --digestfile "/tmp/digest.txt" \
        "${CHUNKED_ID}" "docker://${TARGET}"
    DIGEST=$(cat /tmp/digest.txt)
    echo "==> Pushed ${TARGET} @ ${DIGEST}"

    # Version and stable tags
    if [[ -n "${VERSION}" ]]; then
        podman push \
            --compression-format=zstd:chunked \
            "${CHUNKED_ID}" "docker://${REGISTRY}/${GH_REPO}/${APP_LOWER}:${VERSION}-${ARCH}"
        podman push \
            --compression-format=zstd:chunked \
            "${CHUNKED_ID}" "docker://${REGISTRY}/${GH_REPO}/${APP_LOWER}:stable-${ARCH}"
        echo "==> Tags pushed: latest-${ARCH}, ${VERSION}-${ARCH}, stable-${ARCH}"
    fi

# Assemble and push multi-arch OCI image index
# Usage: just push-manifest-list APP [REGISTRY]
# Reads per-arch digests from /tmp/digests/<arch>/digest.txt (written by CI artifact download).
# CI-only: digest artifact download (uses github.run_id), cosign sign on manifest list.
push-manifest-list app registry="ghcr.io":
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app }}"
    REGISTRY="{{ registry }}"
    APP_LOWER="${APP,,}"
    GH_OWNER="${GITHUB_REPOSITORY_OWNER:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*\)/.*|\1|')}"
    GH_REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*/[^/.]*\).*|\1|')}"

    VERSION=$(just metadata "${APP}" version 2>/dev/null || echo "")
    [[ "${VERSION}" == "null" ]] && VERSION=""
    TITLE=$(just metadata "${APP}" title 2>/dev/null || echo "")
    [[ "${TITLE}" == "null" ]] && TITLE=""
    DESC=$(just metadata "${APP}" description 2>/dev/null || echo "")
    [[ "${DESC}" == "null" ]] && DESC=""
    LICENSE=$(just metadata "${APP}" license 2>/dev/null || echo "")
    [[ "${LICENSE}" == "null" ]] && LICENSE=""
    URL=$(just metadata "${APP}" url 2>/dev/null || echo "")
    [[ "${URL}" == "null" ]] && URL=""

    # Login
    if [[ "${REGISTRY}" == "ghcr.io" ]]; then
        gh auth token | oras login ghcr.io --username "${GH_OWNER}" --password-stdin
    fi

    # Collect per-arch digests
    declare -A ARCH_DIGESTS=()
    for ARCH in x86_64 aarch64; do
        DIGEST_FILE="/tmp/digests/${ARCH}/digest.txt"
        if [[ -f "${DIGEST_FILE}" ]]; then
            DIGEST=$(cat "${DIGEST_FILE}")
            [[ -n "${DIGEST}" ]] && ARCH_DIGESTS[${ARCH}]="${DIGEST}"
        fi
    done
    if [[ "${#ARCH_DIGESTS[@]}" -eq 0 ]]; then
        echo "ERROR: no per-arch digests found in /tmp/digests/ for ${APP}" >&2
        exit 1
    fi

    # Build index-level annotations
    CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    INDEX_ANNOTATIONS=(
        --annotation "org.opencontainers.image.created=${CREATED}"
        --annotation "org.opencontainers.image.vendor=${GH_OWNER}"
        --annotation "org.opencontainers.image.url=https://github.com/${GH_REPO}"
    )
    [[ -n "${VERSION}" ]] && INDEX_ANNOTATIONS+=(--annotation "org.opencontainers.image.version=${VERSION}")
    [[ -n "${TITLE}" ]]   && INDEX_ANNOTATIONS+=(--annotation "org.opencontainers.image.title=${TITLE}")
    [[ -n "${DESC}" ]]    && INDEX_ANNOTATIONS+=(--annotation "org.opencontainers.image.description=${DESC}")
    [[ -n "${LICENSE}" ]] && INDEX_ANNOTATIONS+=(--annotation "org.opencontainers.image.licenses=${LICENSE}")
    [[ -n "${URL}" ]]     && INDEX_ANNOTATIONS+=(--annotation "org.opencontainers.image.source=${URL}")

    # Build digest args (bare sha256:... refs — oras resolves relative to the same repo)
    DIGEST_ARGS=()
    for ARCH in "${!ARCH_DIGESTS[@]}"; do
        DIGEST_ARGS+=("${ARCH_DIGESTS[${ARCH}]}")
    done

    # Push :latest index
    oras manifest index create \
        "${INDEX_ANNOTATIONS[@]}" \
        "${REGISTRY}/${GH_REPO}/${APP_LOWER}:latest" \
        "${DIGEST_ARGS[@]}"
    echo "==> Pushed ${REGISTRY}/${GH_REPO}/${APP_LOWER}:latest (${#ARCH_DIGESTS[@]} platform(s))"

    # Push :version index
    if [[ -n "${VERSION}" ]]; then
        oras manifest index create \
            "${INDEX_ANNOTATIONS[@]}" \
            "${REGISTRY}/${GH_REPO}/${APP_LOWER}:${VERSION}" \
            "${DIGEST_ARGS[@]}"
        echo "==> Pushed ${REGISTRY}/${GH_REPO}/${APP_LOWER}:${VERSION} (${#ARCH_DIGESTS[@]} platform(s))"
    fi

# Run E2E install test locally (reproduces CI e2e-install job).
# Installs from live gh-pages index — app must already be published to ghcr.io.
# x-skip-arch, skip-install-test, x-skip-launch-check flags honoured.
# D-Bus setup is inlined (env vars do not propagate across just recipe calls).
run-test app arch:
    #!/usr/bin/env bash
    set -euo pipefail
    APP="{{ app }}"
    ARCH="{{ arch }}"

    # Skip if arch not supported
    SKIP_ARCH=$(just _skip-arch "${APP}" "${ARCH}")
    if [[ "${SKIP_ARCH}" == "true" ]]; then
        echo "==> SKIP: ${APP} not supported on ${ARCH}"
        exit 0
    fi

    # Skip if install test disabled
    SKIP_INSTALL=$(just metadata "${APP}" skip-install-test 2>/dev/null || echo "")
    if [[ "${SKIP_INSTALL}" == "true" ]]; then
        echo "==> SKIP: install test skipped for ${APP} (skip-install-test: true)"
        exit 0
    fi

    # Resolve app-id
    if [[ -f "flatpaks/${APP}/release.yaml" ]]; then
        APP_ID=$(yq '.app-id' "flatpaks/${APP}/release.yaml")
        MANIFEST="flatpaks/${APP}/release.yaml"
    elif [[ -f "flatpaks/${APP}/manifest.yaml" ]]; then
        APP_ID=$(yq '.app-id' "flatpaks/${APP}/manifest.yaml")
        MANIFEST="flatpaks/${APP}/manifest.yaml"
    else
        # Search by app-id
        MANIFEST=$(find flatpaks -maxdepth 2 \( -name "manifest.yaml" -o -name "release.yaml" \) \
            -exec grep -l "app-id: ${APP}" {} \; | head -1 || echo "")
        if [[ -z "${MANIFEST}" ]]; then
            echo "ERROR: no manifest found for ${APP}" >&2; exit 1
        fi
        APP_ID="${APP}"
    fi

    # Inline D-Bus setup (env vars don't propagate from sub-recipes in Justfile)
    if ! pgrep dbus-daemon >/dev/null 2>&1; then
        mkdir -p /var/lib/dbus && dbus-uuidgen > /var/lib/dbus/machine-id
        mkdir -p /app/var/run/dbus
        grep -q '^messagebus:' /etc/group  || echo 'messagebus:x:111:'                     >> /etc/group
        grep -q '^messagebus:' /etc/passwd || echo 'messagebus:x:111:111::/:/sbin/nologin' >> /etc/passwd
        dbus-daemon --system --fork
        eval "$(dbus-launch --sh-syntax)"
        echo "==> D-Bus started"
    else
        echo "==> D-Bus already running"
    fi

    # Add testhub remote (from live gh-pages index)
    flatpak remote-add --system --if-not-exists testhub \
        oci+https://projectbluefin.github.io/testhub

    # Install
    flatpak install --system --noninteractive testhub "${APP_ID}"

    # Launch check
    SKIP_LAUNCH=$(just metadata "${APP}" skip-launch-check 2>/dev/null || echo "")
    if [[ "${SKIP_LAUNCH}" == "true" ]]; then
        echo "==> SKIP: launch check skipped for ${APP_ID} (skip-launch-check: true)"
    else
        LAUNCH_ARGS=$(yq -r '(.["x-launch-check"] // .["launch-check"] // []) | join(" ")' "${MANIFEST}" 2>/dev/null || echo "")
        set +e
        # shellcheck disable=SC2086
        timeout 5 flatpak run "${APP_ID}" ${LAUNCH_ARGS}
        EXIT=$?
        set -e
        if [[ "${EXIT}" -eq 0 ]]; then
            echo "==> PASS: ${APP_ID} ran and exited cleanly"
        elif [[ "${EXIT}" -eq 124 ]]; then
            echo "==> PASS: ${APP_ID} launched successfully (timeout — app did not self-exit)"
        else
            echo "ERROR: ${APP_ID} launch failed (exit ${EXIT})" >&2; exit 1
        fi
    fi

    # Cleanup
    flatpak uninstall --system --noninteractive "${APP_ID}" || true
    echo "==> run-test done for ${APP_ID}"

# Update gh-pages index from latest ghcr.io digest and push
update-index app="ghostty":
    #!/usr/bin/env bash
    set -euo pipefail
    ARCH=$(uname -m)
    DIGEST=$(cat /tmp/{{app}}-ghcr-digest.txt)
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    GH_REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*/[^/.]*\).*|\1|')}"
    REPO_NAME="${GH_REPO##*/}"
    git worktree add /tmp/${REPO_NAME}-pages gh-pages 2>/dev/null || true
    cd /tmp/${REPO_NAME}-pages && python3 "${REPO_ROOT}/scripts/update-index.py" \
      --app {{app}} \
      --repo "${GH_REPO}/{{app}}" \
      --digest "${DIGEST}" \
      --registry ghcr.io \
      --tags "latest-${ARCH}"
    git -C /tmp/${REPO_NAME}-pages add index/static
    git -C /tmp/${REPO_NAME}-pages diff --cached --quiet && echo "index unchanged, skipping commit" || \
      git -C /tmp/${REPO_NAME}-pages commit -m "feat(index): update {{app}} to ${DIGEST:0:19}"
    git -C /tmp/${REPO_NAME}-pages push origin gh-pages
    git worktree remove /tmp/${REPO_NAME}-pages --force

# Validate index/static JSON is well-formed (must run from gh-pages checkout)
check-index:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    REPO_NAME="$(basename "${REPO_ROOT}")"
    git worktree add /tmp/${REPO_NAME}-pages gh-pages 2>/dev/null || true
    cd /tmp/${REPO_NAME}-pages && python3 "${REPO_ROOT}/scripts/update-index.py" --validate
    git worktree remove /tmp/${REPO_NAME}-pages --force

# Validate manifest lint + appstreamcli for an app (runs inside gnome-49 container)
validate app:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Validating {{app}}..."
    if [ -f "flatpaks/{{app}}/manifest.yaml" ]; then
        echo "==> flatpak-builder-lint on manifest.yaml..."
        podman run --rm -v "$(pwd)/flatpaks/{{app}}:/app:ro" \
            {{container_image}} \
            flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest /app/manifest.yaml
    fi
    METAINFO=$(find flatpaks/{{app}} -name "*.metainfo.xml" | head -1)
    if [ -n "$METAINFO" ]; then
        echo "==> appstreamcli validate on $METAINFO..."
        podman run --rm -v "$(pwd):/workspace:ro" \
            {{container_image}} \
            appstreamcli validate --no-net "/workspace/$METAINFO"
    fi

# Compare current chunkah invocation with upstream README recommendation
check-chunkah:
    @echo "=== Upstream chunkah README (invocation section) ==="
    @curl -fsSL https://raw.githubusercontent.com/coreos/chunkah/main/README.md \
        | grep -A5 -B2 'Containerfile.splitter' | head -20
    @echo ""
    @echo "=== Current build.yml chunkah invocation ==="
    @grep -A5 -B2 'Containerfile.splitter' .github/workflows/build.yml | head -20

# E2E: add remote, list apps, confirm app is visible
verify app="goose":
    #!/usr/bin/env bash
    set -euo pipefail
    GH_REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed 's|.*github.com[:/]\([^/]*/[^/.]*\).*|\1|')}"
    GH_OWNER="${GH_REPO%%/*}"
    REPO_NAME="${GH_REPO##*/}"
    REMOTE_URL="oci+https://${GH_OWNER}.github.io/${REPO_NAME}"
    echo "==> Adding ${REPO_NAME} remote..."
    flatpak remote-add --user --if-not-exists "${REPO_NAME}" "${REMOTE_URL}"
    echo "==> Listing apps from ${REPO_NAME} remote..."
    flatpak remote-ls --user "${REPO_NAME}"
    echo "==> Looking for {{app}}..."
    flatpak remote-ls --user "${REPO_NAME}" | grep -i "{{app}}" \
      && echo "==> {{app}} found in ${REPO_NAME} remote!" \
      || { echo "ERROR: {{app}} not found"; exit 1; }
