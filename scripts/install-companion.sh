#!/bin/bash
# Builds Saguru Cámara, the iPhone companion app, and installs it on an iPhone plugged in with a cable.
#   scripts/install-companion.sh <TEAM_ID> [device UDID]
# TEAM_ID is your Apple developer team (Xcode › Settings › Accounts, or `security find-identity -v -p codesigning`).
# Without a UDID, the first connected iPhone is used. Needs XcodeGen (brew install xcodegen), Xcode signed
# in to that team, and the iPhone unlocked with Developer Mode on.
set -euo pipefail
cd "$(dirname "$0")/../companion"
TEAM="${1:?Uso: scripts/install-companion.sh <TEAM_ID> [UDID]}"
DEVICE="${2:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)}"
[[ -n "$DEVICE" ]] || { echo "No hay ningún iPhone conectado por cable."; exit 1; }
command -v xcodegen >/dev/null || { echo "Falta XcodeGen: brew install xcodegen"; exit 1; }
xcodegen >/dev/null
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
xcodebuild -project SaguruCamara.xcodeproj -scheme SaguruCamara -destination "id=$DEVICE" -derivedDataPath "$BUILD" \
  DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates build | grep -E "error:|BUILD" || true
APP="$BUILD/Build/Products/Debug-iphoneos/SaguruCamara.app"
[[ -d "$APP" ]] || { echo "No se pudo compilar la app."; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -iE "installed|error" || true
xcrun devicectl device process launch --device "$DEVICE" dev.saguru.camara | grep -iE "launched|error" || true
echo "Listo: en Saguru › Cámara elige «iPhone por USB»."
