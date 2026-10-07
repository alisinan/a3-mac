#!/bin/bash
# Builds "A3 Monitor.app". Needs Xcode or Command Line Tools.
#   bash build.sh            -> builds next to this script
#   bash build.sh --install  -> builds and installs into /Applications
set -e
cd "$(dirname "$0")"
APP="A3 Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp ../prompter/a3_prompter.html "$APP/Contents/Resources/a3_prompter.html"
mkdir -p "$APP/Contents/Resources/Tracking"
cp TrackingBridge/*.py "$APP/Contents/Resources/Tracking/"
# Capture the interpreter of an active venv. It can also be changed in the UI.
TRACKING_PYTHON="${A3_TRACKING_PYTHON:-$(command -v python || command -v python3 || true)}"
printf '%s\n' "$TRACKING_PYTHON" > "$APP/Contents/Resources/tracking-python.txt"
# Test pure rotation math with the local Swift compiler before building the UI.
CHECKS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/a3-tracking-checks.XXXXXX")"
trap 'rm -rf "$CHECKS_DIR"' EXIT
swiftc -swift-version 5 TrackingMath.swift ../tests/TrackingMath/main.swift \
  -o "$CHECKS_DIR/TrackingMathChecks"
"$CHECKS_DIR/TrackingMathChecks"
swiftc -O -swift-version 5 \
  -import-objc-header Bridging.h \
  main.swift TrackingMath.swift PoseBridge.swift RotationWindow.swift DisplayRefreshDriver.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
  -framework IOKit -framework IOSurface -framework QuartzCore -framework CoreGraphics \
  -framework ServiceManagement -framework WebKit -framework SceneKit \
  -o "$APP/Contents/MacOS/A3Monitor"
codesign --force --sign - "$APP"
# Each build gets a new ad-hoc signature, so the old Screen Recording grant no longer matches.
# Clear it so macOS asks once, cleanly, on next launch.
tccutil reset ScreenCapture com.yedikare.a3monitor >/dev/null 2>&1 || true

if [ "${1:-}" == "--install" ]; then
  killall A3Monitor >/dev/null 2>&1 || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" "/Applications/$APP"
  touch "/Applications/$APP"
  echo "Installed: /Applications/$APP"
  open "/Applications/$APP"
else
  echo "Built: $(pwd)/$APP"
  echo "Run:   open \"$(pwd)/$APP\""
fi
