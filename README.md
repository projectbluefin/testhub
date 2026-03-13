# Bluefin's OCI Flatpak Remote
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/projectbluefin/testhub/badge)](https://scorecard.dev/viewer/?uri=github.com/projectbluefin/testhub)

An experimental Flatpak remote designed to prototype Flathub's transition to OCI. Someone promised me a magical land of shared storage and composefs, I guess we'll find out. 😄

- Uses [flatpak-tracker](http://github.com/ublue-os/flatpak-tracker) to find flatpaks on Flathub that need runtime updates
  - Auto imports, updates the runtime, builds, and then publishes a test flatpak
  - Help Flathub reviewers with real testing!
  - Tracks all Flatpaks published in Aurora, Bazzite, and Bluefin
- Full flatpak packaging pipeline with full automation using all the latest container tech.
  - [Chunkah](https://github.com/coreos/chunkah) and [zstd:chunked](https://github.com/containers/storage/blob/main/docs/containers-storage-zstd-chunked.md) enabled for partial pulls on the client
- Serves the remote from GitHub Pages; pushes images to `ghcr.io/projectbluefin/testhub`
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

```
flatpak remote-add --user --if-not-exists testhub oci+https://projectbluefin.github.io/testhub
```

### Install packages

[![Build Status](https://github.com/projectbluefin/testhub/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/projectbluefin/testhub/actions/workflows/build.yml?query=branch%3Amain)

| Package | Description | Install |
|---|---|---|
| Ghostty | GPU-accelerated terminal emulator | `flatpak install --user testhub com.mitchellh.ghostty` |
| Goose | Goose AI agent | `flatpak install --user testhub io.github.block.Goose` |
| LM Studio | Local LLM inference | `flatpak install --user testhub ai.lmstudio.LMStudio` |
| Firefox Nightly | Firefox Nightly browser | `flatpak install --user testhub org.mozilla.firefox.nightly` |
| Thunderbird Nightly | Thunderbird Nightly email client | `flatpak install --user testhub org.mozilla.thunderbird.nightly` |
| VirtualBox | Oracle VirtualBox | `flatpak install --user testhub org.virtualbox.VirtualBox` |

<details>
<summary>Copy/paste install commands</summary>

```bash
flatpak install --user testhub com.mitchellh.ghostty
```

```bash
flatpak install --user testhub io.github.block.Goose
```

```bash
flatpak install --user testhub ai.lmstudio.LMStudio
```

```bash
flatpak install --user testhub org.mozilla.firefox.nightly
```

```bash
flatpak install --user testhub org.mozilla.thunderbird.nightly
```

```bash
flatpak install --user testhub org.virtualbox.VirtualBox
```

</details>

### Update all

```
flatpak update --user
```

### Verifying the image

All images are signed and include an SPDX SBOM. Replace `<app>` with the app name (e.g. `goose`).

Verify the signature:

```bash
cosign verify \
  --certificate-identity=https://github.com/projectbluefin/testhub/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/projectbluefin/testhub/<app>:latest
```

Exit 0 means valid. See all attached supply chain artifacts:

```bash
cosign tree ghcr.io/projectbluefin/testhub/<app>:latest
```

Inspect the SBOM:

```bash
cosign verify-attestation \
  --type spdxjson \
  --certificate-identity=https://github.com/projectbluefin/testhub/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/projectbluefin/testhub/<app>:latest \
  | jq '.payload | @base64d | fromjson | .predicate'
```

Scan for vulnerabilities:

```bash
grype registry:ghcr.io/projectbluefin/testhub/<app>:latest
```
