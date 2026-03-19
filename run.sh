#!/usr/bin/env bash

set -euo pipefail

APP_NAME="${APP_NAME:-recall}"
PROJECT_PATH="${PROJECT_PATH:-recall.xcodeproj}"
SCHEME="${SCHEME:-recall}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/xcode-derived-data}"
DESTINATION="${DESTINATION:-platform=macOS}"
BUNDLE_ID="${BUNDLE_ID:-com.summarizecontent.app}"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "$DESTINATION" \
  build

APP_BUNDLE_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "Built app bundle not found: $APP_BUNDLE_PATH" >&2
  exit 1
fi

# Reuse of an existing hidden instance makes it look like nothing launched.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1

open "$APP_BUNDLE_PATH"
