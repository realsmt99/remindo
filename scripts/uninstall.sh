#!/bin/bash
# Removes Remindo: Claude Code hooks, login item, the app, ~/.remindo and preferences.
set -uo pipefail

if [[ -x "$HOME/.remindo/bin/remindo" ]]; then
  "$HOME/.remindo/bin/remindo" uninstall-claude || true
fi

APP="$HOME/Applications/Remindo.app"
if [[ -x "$APP/Contents/MacOS/Remindo" ]]; then
  pkill -x Remindo 2>/dev/null || true
  "$APP/Contents/MacOS/Remindo" --unregister-login 2>/dev/null || true
fi
pkill -x Remindo 2>/dev/null || true

rm -rf "$APP" "$HOME/.remindo"
[[ -L "$HOME/.local/bin/remindo" ]] && rm -f "$HOME/.local/bin/remindo"
defaults delete dev.remindo.Remindo >/dev/null 2>&1 || true
echo "✓ Remindo removed"
