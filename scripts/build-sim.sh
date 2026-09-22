#!/usr/bin/env bash
# Builds the app and the keyboard extension for the iOS simulator, installs them and launches
# the container app. Override the destination with DESTINATION=... DEVICE=...
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
DEVICE="${DEVICE:-iPhone 17}"
DERIVED_DATA=".build/DerivedData"

xcodebuild -project arkey.xcodeproj \
  -scheme arkey \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/arkey.app"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.acehinnnqru.arkey
