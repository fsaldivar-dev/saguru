#!/bin/bash
# Runs the camera agent through the ways apps use a camera, in the booted simulator, and says which end badly.
#   scripts/test-camera.sh            every flow
#   scripts/test-camera.sh photo      only that one, with everything it prints
# Each flow is its own process with Saguru's agent loaded, so a crash in one does not hide the rest.
# Needs build/Saguru.app (scripts/build.sh) and a booted simulator.
set -uo pipefail
cd "$(dirname "$0")/.."
AGENT="$PWD/build/Saguru.app/Contents/Resources/SaguruAgent.dylib"
[[ -f "$AGENT" ]] || { echo "Falta $AGENT: ejecuta scripts/build.sh"; exit 1; }
DEVICE="$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)"
[[ -n "$DEVICE" ]] || { echo "No hay ningún simulador arrancado"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A picture for the camera: a grey ramp in Saguru's frame format (see agent/SaguruCamera.m).
python3 - "$WORK/frame.bgra" <<'PY'
import struct, sys
w, h = 1080, 1920
row = bytes(b for x in range(w) for b in (x * 255 // w, 120, 255 - x * 255 // w, 255))
with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<5I", 0x4D434753, 2, w, h, w * 4) + bytes(44))
    for _ in range(h): f.write(row)
PY

FRAMEWORKS="-framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework UIKit -framework CoreGraphics"
for name in flows teardown; do
  xcrun -sdk iphonesimulator clang -arch "$(uname -m)" -fobjc-arc -mios-simulator-version-min=17.0 -Wno-deprecated-declarations $FRAMEWORKS "tests/camera/$name.m" -o "$WORK/$name" || exit 1
done

run() { SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$AGENT" SIMCTL_CHILD_SAGURU_CAM_FOLDER="$WORK" perl -e 'alarm 90; exec @ARGV' xcrun simctl spawn "$DEVICE" "$@" 2>&1; }

if [[ $# -gt 0 ]]; then
  if [[ "$1" == teardown ]]; then run "$WORK/teardown"; else run "$WORK/flows" "$1"; fi
  exit
fi
failed=0
for flow in describe structs switch churn sessions layer photo still movie meta observe audio manual discover; do
  out="$(run "$WORK/flows" "$flow" | grep -v 'has no stand-in\|session started')"
  if grep -q '^OK$' <<<"$out"; then echo "✅ $flow"; else echo "❌ $flow: $(grep -i 'terminated\|reason' <<<"$out" | head -2 | tr '\n' ' ' | cut -c1-240)"; failed=1; fi
done
out="$(run "$WORK/teardown")"
if grep -q 'TODO BIEN' <<<"$out"; then echo "✅ teardown"; else echo "❌ teardown: $(grep -i 'terminated\|soltar' <<<"$out" | tail -2 | tr '\n' ' ')"; failed=1; fi
exit $failed
