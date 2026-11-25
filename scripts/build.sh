#!/bin/bash
# Builds build/Simuru.app (the `simuru` CLI lives inside it).
#   scripts/build.sh            build
#   scripts/build.sh --install  build, then symlink the CLI into /usr/local/bin (or ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/simuru"

APP="build/Simuru.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/simuru"

# Icon: assets/icon_1024.png is the master (824 px tile centred on a transparent 1024 px canvas).
# If it is missing, a placeholder is drawn by scripts/make-icon.swift.
mkdir -p assets
[[ -f assets/icon_1024.png ]] || swift scripts/make-icon.swift assets/icon_1024.png >/dev/null
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# LSUIElement: no Dock icon, Simuru behaves as an extension of the Simulator.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Simuru</string>
  <key>CFBundleDisplayName</key><string>Simuru</string>
  <key>CFBundleIdentifier</key><string>dev.simuru.app</string>
  <key>CFBundleExecutable</key><string>simuru</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a development certificate when there is one: macOS ties the Accessibility permission to the
# signature, and an ad-hoc signature changes on every build, so the permission would be asked for again
# after each rebuild. Without a certificate it falls back to ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1
echo "OK  $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/usr/local/bin"
  [[ -w "$DEST" ]] || DEST="$HOME/.local/bin"
  mkdir -p "$DEST"
  ln -sf "$PWD/$APP/Contents/MacOS/simuru" "$DEST/simuru"
  echo "OK  $DEST/simuru"
  case ":$PATH:" in *":$DEST:"*) ;; *) echo "    (añade $DEST a tu PATH)";; esac
fi
