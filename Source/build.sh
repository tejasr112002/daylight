#!/bin/zsh
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d /private/tmp/daylight-build.XXXXXX)"
APP_DIR="$BUILD_DIR/Daylight.app"
mkdir -p "$APP_DIR/Contents/MacOS"
swiftc "$SOURCE_DIR/Daylight.swift" -o "$APP_DIR/Contents/MacOS/Daylight" -target arm64-apple-macosx14.0 -module-cache-path /private/tmp/daylight-module-cache -framework AppKit -framework SwiftUI -O
cp "$SOURCE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Resources" && cp "$SOURCE_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
ditto "$APP_DIR" "$SOURCE_DIR/../Daylight.app"
xattr -dr com.apple.FinderInfo "$SOURCE_DIR/../Daylight.app" 2>/dev/null || true
