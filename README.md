# Bluefin's OCI Flatpak Remote

An experimental Flatpak remote designed to prototype Flathub's transition to OCI. Someone promised me a magical land of shared storage and composefs, I guess we'll find out. 😄

- Flatpak packaging pipeline with full automation
- Serves the remote from GitHub Pages; pushes images to `ghcr.io/projectbluefin/testhub`
- [Chunkah](https://github.com/coreos/chunkah) and [zstd:chunked](https://github.com/containers/storage/blob/main/docs/containers-storage-zstd-chunked.md) enabled for partial pulls on the client
- Under no circumstance will this remote ever go to production
  - Things the core team wants to test (Ghostty, Goose) to hopefully aid in getting their flatpaks getting submitted to flathub.
  - Purpose is to gather data for using OCI for Flathub distribution.

This potentially unlocks all container registries and git forges as Flatpak hosts in a format supported by flatpak. This is a prototype and not a replacement or substitute for Flathub's official process.

## Key Dependencies

- [Flatpak](https://flatpak.org/) — Application sandboxing and distribution framework
- [OCI Image Format Specification](https://github.com/opencontainers/image-spec) — Standard for container image formats
- [bootc](https://containers.github.io/bootc/) — Transactional, in-place operating system updates using OCI images
- [Podman](https://podman.io/) — Daemonless OCI container engine
- [Skopeo](https://github.com/containers/skopeo) — Tool for inspecting and copying container images
- [flatpak-builder](https://docs.flatpak.org/en/latest/flatpak-builder.html) — Builds Flatpak applications from manifests

## Usage

### Add this remote

    flatpak remote-add --if-not-exists testhub oci+https://projectbluefin.github.io/testhub

### Install packages

| Package | App ID | Description |
|---|---|---|
| Ghostty | `com.mitchellh.ghostty` | GPU-accelerated terminal emulator |
| Goose | `io.github.block.Goose` | Goose AI agent |
| LM Studio | `ai.lmstudio.LMStudio` | Local LLM inference |
| Firefox Nightly | `org.mozilla.firefox.nightly` | Firefox Nightly browser |
| Thunderbird Nightly | `org.mozilla.thunderbird.nightly` | Thunderbird Nightly email client |
| VirtualBox | `org.virtualbox.VirtualBox` | Oracle VirtualBox |

    flatpak install testhub com.mitchellh.ghostty
    flatpak install testhub io.github.block.Goose
    flatpak install testhub ai.lmstudio.LMStudio
    flatpak install testhub org.mozilla.firefox.nightly
    flatpak install testhub org.mozilla.thunderbird.nightly
    flatpak install testhub org.virtualbox.VirtualBox

### Update all

    flatpak update

### Checking the Signature

All images are signed with [cosign](https://docs.sigstore.dev/cosign/overview/) keyless signing via GitHub Actions OIDC. Replace `<app>` with the app name (e.g. `goose`):

```bash
cosign verify \
  --certificate-identity=https://github.com/projectbluefin/testhub/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/projectbluefin/testhub/<app>:latest
```

Exit 0 means the signature is valid. Output is JSON with the certificate details (workflow ref, commit SHA, build timestamp).

### Checking the SBOMs

SBOM attestations (SPDX format) are attached to every image. Replace `<app>` as above:

```bash
cosign verify-attestation \
  --type spdxjson \
  --certificate-identity=https://github.com/projectbluefin/testhub/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/projectbluefin/testhub/<app>:latest \
  | jq '.payload | @base64d | fromjson'
```

Output is the full SPDX document listing all packages and dependencies in the image.
