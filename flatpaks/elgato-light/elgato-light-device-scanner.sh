#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/app/share/elgato-light"
export GSETTINGS_SCHEMA_DIR="/app/share/glib-2.0/schemas"

# Helper command for standalone device scanner UI.
exec gjs -m "${APP_DIR}/device-scanner.js" "$@"
