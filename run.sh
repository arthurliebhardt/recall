#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="recall"
PROJECT_PATH="$ROOT_DIR/recall.xcodeproj"
SCHEME="recall"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
BUNDLE_ID="com.summarizecontent.app"
ALLOW_SWIFT_RUN_FALLBACK="${ALLOW_SWIFT_RUN_FALLBACK:-0}"

quit_existing_app() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 1
}

start_with_swift_run() {
  echo "Using 'swift run $APP_NAME'. Screen Recording permission may not attach to the bundled recall app in this mode."
  quit_existing_app
  cd "$ROOT_DIR"
  exec swift run "$APP_NAME"
}

BUILD_LOG="$(mktemp -t ${APP_NAME}-xcodebuild.XXXXXX.log)"

if ! xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build | tee "$BUILD_LOG"
then
  if grep -q "missing Metal Toolchain" "$BUILD_LOG"; then
    echo "xcodebuild failed because the Metal Toolchain is not installed." >&2
    echo "To launch the real app bundle and get Screen Recording permissions under 'recall', install it with:" >&2
    echo "  xcodebuild -downloadComponent MetalToolchain" >&2
    echo >&2
    echo "After installing, rerun ./run.sh." >&2
    echo "If you still want the temporary CLI fallback, run:" >&2
    echo "  ALLOW_SWIFT_RUN_FALLBACK=1 ./run.sh" >&2

    if [[ "$ALLOW_SWIFT_RUN_FALLBACK" == "1" ]]; then
      start_with_swift_run
      exit 0
    fi

    exit 1
  fi

  echo "xcodebuild failed. Log: $BUILD_LOG" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app bundle not found: $APP_PATH" >&2
  exit 1
fi

quit_existing_app
open "$APP_PATH"
