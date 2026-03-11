# Renovate

Renovate manages dependency pins in this repo. Known limitations:

## manifest.yaml autoReplaceStringTemplate fragility

The multiline `matchString` spanning `x-version` through `sha256` makes faithful
reconstruction fragile when fields are not adjacent.

If `autoReplaceStringTemplate` produces wrong output: restructure `manifest.yaml` to place
`x-version` immediately above the source block, or handle `x-version` in a separate regex
manager.

## sha256 not computed for github-releases artifacts

`currentDigest`/`newDigest` in `autoReplaceStringTemplate` only works when Renovate
downloads the artifact. For the `github-releases` datasource, Renovate does **not** download
to compute sha256.

Validate when Renovate first runs on a goose update — a post-Renovate hook or manual update
may be required.

## Plan authoring note

Check existing `workflow_dispatch` inputs before adding new ones. The `app` input already
gates per-app rebuilds. Do not add a `force-rebuild` boolean if the existing `app` input
already covers the use case.
