#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/app/share/elgato-light"
export GSETTINGS_SCHEMA_DIR="/app/share/glib-2.0/schemas"

# Standalone app scope only. GNOME Shell extension runtime remains host-side.
exec gjs -m "${APP_DIR}/preferences-app.js" "$@"
