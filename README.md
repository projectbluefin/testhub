# OCI Flatpak Remote

An experimental Flatpak remote designed to prototype Flathub's transition to OCI. Someone promised me a magical land of shared storage and composefs, I guess we'll find out. 😄

- Flatpak packaging pipeline with full automation
- Serves the remote from GitHub Pages; pushes images to `ghcr.io/<org>/<repo-name>`
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

    flatpak remote-add --if-not-exists jorgehub oci+https://projectbluefin.github.io/jorgehub

### Install packages

| Package | App ID | Description |
|---|---|---|
| Ghostty | `com.mitchellh.ghostty` | GPU-accelerated terminal emulator |
| Goose | `io.github.block.Goose` | Goose AI agent |
| LM Studio | `ai.lmstudio.LMStudio` | Local LLM inference |
| Firefox Nightly | `org.mozilla.firefox.nightly` | Firefox Nightly browser |
| Thunderbird Nightly | `org.mozilla.Thunderbird` | Thunderbird Nightly email client |
| VirtualBox | `org.virtualbox.VirtualBox` | Oracle VirtualBox |

    flatpak install jorgehub com.mitchellh.ghostty
    flatpak install jorgehub io.github.block.Goose
    flatpak install jorgehub ai.lmstudio.LMStudio
    flatpak install jorgehub org.mozilla.firefox.nightly
    flatpak install jorgehub org.mozilla.Thunderbird
    flatpak install jorgehub org.virtualbox.VirtualBox

### Update all

    flatpak update

## Fork and host your own

This repo is a self-contained pipeline. Fork it, enable GitHub Pages, and you have your own Flatpak OCI remote hosted on ghcr.io.

### 1. Fork the repository

Fork on GitHub, then set up GitHub Pages for the fork:

1. Go to **Settings → Pages**
2. Set **Source** to **Deploy from a branch**
3. Set **Branch** to `gh-pages`, folder `/` (root)
4. Save — GitHub will show you the Pages URL: `https://<your-org>.github.io/<repo-name>`

### 2. Give Actions permission to push

The pipeline pushes OCI images to `ghcr.io` and updates the `gh-pages` branch using the default `GITHUB_TOKEN`. No extra secrets are needed, but the token needs write permission:

1. Go to **Settings → Actions → General**
2. Under **Workflow permissions**, select **Read and write permissions**
3. Save

### 3. Add an app

Two packaging paths are available depending on whether an upstream `.flatpak` bundle exists:

**Bundle repack** (upstream distributes a `.flatpak` file — faster, no compile step):

Copy `flatpaks/TEMPLATE/release.yaml.example` to `flatpaks/<app-id>/release.yaml` and fill in:

```yaml
app-id: com.example.MyApp
version: "1.2.3"
url: https://example.com/releases/v1.2.3/MyApp.flatpak
sha256: <sha256 of the file above>
```

Compute the sha256 with:

    curl -sL <url> | sha256sum

**Build from source** (no upstream bundle — uses flatpak-builder):

Copy `flatpaks/TEMPLATE/manifest.yaml.example` to `flatpaks/<app-id>/manifest.yaml` and fill in the standard flatpak-builder fields. The `x-version` field controls the OCI tag.

### 4. Trigger a build

Once your app directory is committed and pushed, trigger a build from the **Actions** tab:

1. Go to **Actions → Build Flatpak OCI**
2. Click **Run workflow**
3. Enter the app directory name (e.g. `goose`) in the **app** field
4. Click **Run workflow**

The pipeline builds for `x86_64` and `aarch64`, pushes the OCI image to `ghcr.io/<org>/<repo>`, and regenerates the Flatpak index on the `gh-pages` branch.

### 5. Add the remote and install

Replace `<org>` and `<repo-name>` with your GitHub org/user and repo name:

    flatpak remote-add --if-not-exists <repo-name> oci+https://<org>.github.io/<repo-name>
    flatpak install <repo-name> com.example.MyApp
