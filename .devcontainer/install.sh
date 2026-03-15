#!/usr/bin/env bash
# devc — CLI helper for the testhub devcontainer
# Adapted from trailofbits/devcontainer-setup (https://skills.sh/trailofbits/skills/devcontainer-setup)
#
# Usage:
#   .devcontainer/install.sh self-install   # install `devc` to ~/.local/bin
#   devc up                                 # start the devcontainer
#   devc shell                              # open a shell in the running container
#   devc build <app>                        # run `just loop <app>` inside the container
#   devc stop                               # stop the devcontainer

set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"

case "${1:-help}" in
  self-install)
    mkdir -p "$HOME/.local/bin"
    ln -sf "$SCRIPT_PATH" "$HOME/.local/bin/devc"
    echo "✓ devc installed to ~/.local/bin/devc"
    echo "  Make sure ~/.local/bin is on your PATH"
    ;;

  up)
    echo "Starting devcontainer..."
    devcontainer up --workspace-folder "$WORKSPACE_DIR"
    ;;

  shell)
    devcontainer exec --workspace-folder "$WORKSPACE_DIR" bash
    ;;

  build)
    APP="${2:-}"
    if [[ -z "$APP" ]]; then
      echo "Usage: devc build <app>" >&2
      exit 1
    fi
    devcontainer exec --workspace-folder "$WORKSPACE_DIR" just loop "$APP"
    ;;

  stop)
    # devcontainer CLI doesn't have stop; find and stop the container
    CONTAINER=$(docker ps --filter "label=devcontainer.local_folder=$WORKSPACE_DIR" -q | head -1)
    if [[ -z "$CONTAINER" ]]; then
      echo "No running devcontainer found for $WORKSPACE_DIR" >&2
      exit 1
    fi
    docker stop "$CONTAINER"
    echo "✓ devcontainer stopped"
    ;;

  help|*)
    echo "Usage: devc <command>"
    echo ""
    echo "Commands:"
    echo "  self-install   Install devc to ~/.local/bin"
    echo "  up             Start the devcontainer"
    echo "  shell          Open a shell in the running container"
    echo "  build <app>    Run \`just loop <app>\` inside the container"
    echo "  stop           Stop the running container"
    ;;
esac
