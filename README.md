# jorgehub

An experimental flatpack remoted designed to prototype Flathub's transition to OCI. Someone promised me a magical land of shared storage and composefs, I guess we'll find out. 😄

- Flatpak packing skills for automation
- Serves the remote from github pages to clients, pushes the flatpak to [the registry](https://github.com/users/castrojo/packages/container/package/jorgehub%2Fghostty)
- [Chunkah](https://github.com/coreos/chunkah) and [zstd:chunked](https://github.com/containers/storage/blob/main/docs/containers-storage-zstd-chunked.md) enabled for partial pulls
- We need data when this lands in OS bootc images so we might as well get going.

This potentially unlocks all container registries and git forges as Flatpak hosts in a format supported by flatpak. This is a prototype and not a replacement or substitute for Flathub's official process, this is designed to test the package format changes.

## Key Dependencies

- [Flatpak](https://flatpak.org/) — Application sandboxing and distribution framework
- [OCI Image Format Specification](https://github.com/opencontainers/image-spec) — Standard for container image formats
- [bootc](https://containers.github.io/bootc/) — Transactional, in-place operating system updates using OCI images
- [Podman](https://podman.io/) — Daemonless OCI container engine
- [Skopeo](https://github.com/containers/skopeo) — Tool for inspecting and copying container images
- [flatpak-builder](https://docs.flatpak.org/en/latest/flatpak-builder.html) — Builds Flatpak applications from manifests

## Usage

### Add this remote

    flatpak remote-add --if-not-exists jorgehub oci+https://castrojo.github.io/jorgehub

### Install packages

| Package | App ID | Description |
|---|---|---|
| Ghostty | `com.mitchellh.ghostty` | GPU-accelerated terminal emulator |
| Goose | `io.github.block.Goose` | Goose AI agent |
| Firefox Nightly | `org.mozilla.firefox` | Firefox Nightly browser |

    flatpak install jorgehub com.mitchellh.ghostty
    flatpak install jorgehub io.github.block.Goose
    flatpak install jorgehub org.mozilla.firefox

### Update all

    flatpak update
