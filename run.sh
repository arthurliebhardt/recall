#!/usr/bin/env bash

set -euo pipefail

APP_NAME="recall"
BUILD_ROOT="${BUILD_ROOT:-build}"
APP_BUNDLE_PATH="$BUILD_ROOT/$APP_NAME.app"
CONTENTS_PATH="$APP_BUNDLE_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"

swift build

BIN_PATH="$(swift build --show-bin-path)/$APP_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Built executable not found: $BIN_PATH" >&2
  exit 1
fi

mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"

ln -sf "$BIN_PATH" "$MACOS_PATH/$APP_NAME"

if [[ -f "recall/AppIcon.icns" ]]; then
  cp "recall/AppIcon.icns" "$RESOURCES_PATH/AppIcon.icns"
fi

cat > "$CONTENTS_PATH/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.summarizecontent.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
EOF

open "$APP_BUNDLE_PATH"
