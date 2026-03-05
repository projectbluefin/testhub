set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    just --list

# Bootstrap: create repo, gh-pages branch, enable Pages (run once)
bootstrap:
    bash scripts/bootstrap.sh

# Build all apps locally using podman registry
build:
    bash scripts/build-local.sh

# Validate index/static JSON is well-formed
check-index:
    python3 scripts/update-index.py --validate

# Push skill updates to opencode-config after a successful run
harvest:
    bash scripts/harvest-skills.sh
