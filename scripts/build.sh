#!/bin/bash
# Builds build/Remindo.app (release, ad-hoc signed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Universal by default (Apple Silicon + Intel). REMINDO_NATIVE=1 builds only for this Mac (faster).
if [[ "${REMINDO_NATIVE:-0}" == "1" ]]; then
  ARCH_FLAGS=()
  echo "→ Compiling Remindo (release, this Mac only)…"
else
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  echo "→ Compiling Remindo (release, universal: Apple Silicon + Intel)…"
fi
swift build -c release --product Remindo ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$ROOT/build/Remindo.app"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Remindo" "$APP/Contents/MacOS/Remindo"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/bin/remindo" "$APP/Contents/Resources/remindo"
chmod 755 "$APP/Contents/MacOS/Remindo" "$APP/Contents/Resources/remindo"

echo "→ Drawing the app icon…"
"$APP/Contents/MacOS/Remindo" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "→ Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "✓ Built $APP"
