# Security — Image Verification

All OCI images published from this repository are signed with [cosign](https://docs.sigstore.dev/cosign/overview/) keyless signing via GitHub Actions OIDC. SBOM attestations are attached to every image.

## Prerequisites

```bash
brew install cosign
```

## Verify image signature

The `--certificate-identity` must exactly match the GitHub Actions workflow URL for the signing repository.

Replace `<app>` with the app directory name (e.g. `goose`) and `<tag>` with the version tag (e.g. `v0.9.17`).

```bash
cosign verify \
  --certificate-identity=https://github.com/projectbluefin/jorgehub/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/projectbluefin/jorgehub/<app>:<tag>
```

Exit 0 means the signature is valid. Output is JSON containing the certificate details (workflow ref, commit SHA, build timestamp).

## Verify SBOM attestation

Replace `<app>` and `<tag>` as above.

```bash
cosign verify-attestation \
  --type spdxjson \
  --certificate-identity=https://github.com/projectbluefin/jorgehub/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/projectbluefin/jorgehub/<app>:<tag> \
  | jq '.payload | @base64d | fromjson'
```

Output is the full SPDX document listing all packages and dependencies in the image.
