#!/bin/bash
# Builds build/Saguru.app (the `saguru` CLI lives inside it).
#   scripts/build.sh            build
#   scripts/build.sh --install  build, then symlink the CLI into /usr/local/bin (or ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/saguru"

APP="build/Saguru.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/saguru"

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

# The agent (network monitor and pretend camera): a small library that Saguru loads into an app when it launches it in the simulator.
xcrun -sdk iphonesimulator clang -arch arm64 -arch x86_64 -dynamiclib -fobjc-arc -O2 -mios-simulator-version-min=15.0 \
  -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage \
  -framework UIKit -framework QuartzCore -framework CoreGraphics -framework IOSurface -framework ImageIO \
  agent/SaguruAgent.m agent/SaguruCamera.m agent/SaguruVision.m -o "$APP/Contents/Resources/SaguruAgent.dylib"

# scrcpy's server, to use an Android phone as the camera's source (Apache 2.0, see vendor/scrcpy).
cp vendor/scrcpy/scrcpy-server "$APP/Contents/Resources/scrcpy-server"
cp vendor/scrcpy/VERSION "$APP/Contents/Resources/scrcpy-server.version"
cp vendor/scrcpy/LICENSE "$APP/Contents/Resources/scrcpy-LICENSE.txt"

# LSUIElement: no Dock icon, Saguru behaves as an extension of the Simulator.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Saguru</string>
  <key>CFBundleDisplayName</key><string>Saguru</string>
  <key>CFBundleIdentifier</key><string>dev.saguru.app</string>
  <key>CFBundleExecutable</key><string>saguru</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Saguru pasa la imagen de esta cámara a la app del simulador que elijas.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
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
  ln -sf "$PWD/$APP/Contents/MacOS/saguru" "$DEST/saguru"
  echo "OK  $DEST/saguru"
  case ":$PATH:" in *":$DEST:"*) ;; *) echo "    (añade $DEST a tu PATH)";; esac
fi
