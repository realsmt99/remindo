#!/bin/bash
# Builds Remindo, installs it to ~/Applications, installs the `remindo` CLI to
# ~/.remindo/bin, links Claude Code (unless REMINDO_SKIP_CLAUDE=1) and launches it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"

DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Remindo.app"
mkdir -p "$DEST_DIR"

if pgrep -x Remindo >/dev/null 2>&1; then
  echo "→ Restarting Remindo…"
  pkill -x Remindo || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Remindo >/dev/null 2>&1 || break; sleep 0.2; done
fi

rm -rf "$DEST"
cp -R "$ROOT/build/Remindo.app" "$DEST"

mkdir -p "$HOME/.remindo/bin"
install -m 755 "$ROOT/bin/remindo" "$HOME/.remindo/bin/remindo"
echo "✓ CLI at ~/.remindo/bin/remindo"

if [[ "${REMINDO_SKIP_CLAUDE:-0}" != "1" ]]; then
  "$HOME/.remindo/bin/remindo" install-claude
fi

open "$DEST"
echo "✓ Remindo is running (look for the spark in your menu bar)"
echo "  Try it: ~/.remindo/bin/remindo test"

# Make `remindo` a terminal command (e.g. `remindo go`).
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/.remindo/bin/remindo" "$HOME/.local/bin/remindo"
if /bin/zsh -lic 'whence -p remindo' >/dev/null 2>&1; then
  echo "✓ 'remindo' command available (try: remindo go)"
else
  echo "✓ 'remindo' installed at ~/.local/bin/remindo"
  echo "  To use 'remindo' from any terminal, add ~/.local/bin to your PATH once:"
  echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
fi
