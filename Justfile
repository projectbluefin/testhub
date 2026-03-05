set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    just --list

# Bootstrap: create repo, gh-pages branch, enable Pages (run once)
bootstrap:
    bash scripts/bootstrap.sh

# Build app locally, push to ghcr.io with zstd:chunked, update index
build app="ghostty":
    bash scripts/build-local.sh {{app}}

# Update gh-pages index from latest ghcr.io digest and push
update-index app="ghostty":
    #!/usr/bin/env bash
    set -euo pipefail
    DIGEST=$(cat /tmp/{{app}}-ghcr-digest.txt)
    git worktree add /tmp/jorgehub-pages gh-pages 2>/dev/null || true
    cd /tmp/jorgehub-pages && python3 /var/home/jorge/src/jorgehub/scripts/update-index.py \
      --app {{app}} \
      --digest "${DIGEST}" \
      --registry ghcr.io
    git -C /tmp/jorgehub-pages add index/static
    git -C /tmp/jorgehub-pages diff --cached --quiet && echo "index unchanged, skipping commit" || \
      git -C /tmp/jorgehub-pages commit -m "feat(index): update {{app}} to ${DIGEST:0:19}"
    git -C /tmp/jorgehub-pages push origin gh-pages
    git worktree remove /tmp/jorgehub-pages --force

# Validate index/static JSON is well-formed
check-index:
    python3 scripts/update-index.py --validate

# Push skill updates to opencode-config after a successful run
harvest:
    bash scripts/harvest-skills.sh
