#!/bin/sh
# build-device.sh — device-config build for ZYRAXIS-iOS on a Mac.
# Usage (from the project root):
#   chmod +x Scripts/*.sh
#   ./Scripts/build-device.sh                 # generic iOS-device build
#   DEVICE_UDID=<udid> ./Scripts/build-device.sh   # build for one connected iPhone
#   DEVICE_NAME="Yasir's iPhone" ./Scripts/build-device.sh
#
# A generic build proves the device configuration compiles. Installing onto a
# phone is done from Xcode (Run) with automatic signing — this script never
# pretends an install succeeded.
set -u

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/ZYRAXIS-iOS.xcodeproj"
SCHEME="ZYRAXIS-iOS"

fail() { echo "build-device: FAIL — $1" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found. Install Xcode first."
[ -d "$PROJECT" ] || fail "project not found at $PROJECT"

if [ -n "${DEVICE_UDID:-}" ]; then
  DEST="platform=iOS,id=$DEVICE_UDID"
elif [ -n "${DEVICE_NAME:-}" ]; then
  DEST="platform=iOS,name=$DEVICE_NAME"
else
  DEST="generic/platform=iOS"
  echo "build-device: no DEVICE_UDID/DEVICE_NAME set — building for generic iOS device."
  echo "build-device: to target your iPhone: DEVICE_NAME=\"<name>\" ./Scripts/build-device.sh"
fi

echo "build-device: destination: $DEST"
if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -destination "$DEST" build; then
  echo "build-device: BUILD SUCCEEDED (destination: $DEST)"
  if [ "$DEST" = "generic/platform=iOS" ]; then
    echo "build-device: NOTE: generic build only — connect the iPhone, select it in Xcode, press Run to install."
  fi
else
  fail "xcodebuild reported failure (see log above)."
fi
