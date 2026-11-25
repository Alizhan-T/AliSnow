#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AliSnow"
VERSION="${1:-1.0.0}"
BUILD_DIR="$ROOT_DIR/build/ReleaseBuild"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
APP_PATH="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"

echo "==> Building ${APP_NAME} (${VERSION}) in Release configuration..."
xcodebuild \
  -project "$ROOT_DIR/${APP_NAME}.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  MARKETING_VERSION="$VERSION" \
  build

if [ ! -d "$APP_PATH" ]; then
  echo "Error: Built app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Packaging DMG at $DMG_PATH..."
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR" "$DIST_DIR"

cp -R "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> Done!"
echo "    App: $APP_PATH"
echo "    DMG: $DMG_PATH"
echo ""
echo "To install locally right now:"
echo "    rm -rf /Applications/${APP_NAME}.app && cp -R \"$APP_PATH\" /Applications/${APP_NAME}.app"
