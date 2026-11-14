#!/bin/zsh
# Builds Multipasta in Release (Apple Silicon and Intel), signs it and packs it into a disk image for a GitHub release.
# Usage: scripts/build-dmg.sh
#   SIGN_IDENTITY  codesign identity; "-" (the default) signs ad-hoc, which is enough to run the app
#   SIGN_TIMESTAMP set to "none" for a self-signed identity (no Apple timestamp)
#                  after Privacy & Security -> Open Anyway
#   DEVELOPER_DIR  Xcode to build with; defaults to /Applications/Xcode.app when xcode-select points
#                  to the Command Line Tools
#   DERIVED_DATA   xcodebuild derived data folder (default: build/dd-dmg)
# Output: build/Multipasta-<version>.dmg and a copy named build/Multipasta.dmg (the release asset name).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Multipasta"
SCHEME="Maccy"
ENTITLEMENTS="Maccy/Maccy.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DERIVED_DATA="${DERIVED_DATA:-build/dd-dmg}"

# xcodebuild needs a full Xcode, not just the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p 2>/dev/null)" != *".app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if [[ -n "${DEVELOPER_DIR:-}" ]] && [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode not found at $DEVELOPER_DIR; install Xcode or set DEVELOPER_DIR" >&2
  exit 1
fi

echo "building $APP_NAME (Release, arm64 + x86_64)..."
xcodebuild \
  -project Maccy.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  -quiet \
  build

APP="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
[[ -d "$APP" ]] || { echo "build finished but $APP is missing" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

# Re-sign the whole bundle with the hardened runtime: ad-hoc by default, or with SIGN_IDENTITY.
SIGN_ARGS=(--force --deep --options runtime --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY")
# A secure timestamp needs an Apple-issued certificate; ad-hoc and self-signed identities skip it.
if [[ "$SIGN_IDENTITY" == "-" || "${SIGN_TIMESTAMP:-}" == "none" ]]; then
  SIGN_ARGS+=(--timestamp=none)
else
  SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed: $APP ($(lipo -archs "$APP/Contents/MacOS/${APP_NAME}"), identity: $SIGN_IDENTITY)"

# A plain disk image: the app next to a link to Applications, ready to drag over.
STAGE="build/dmg-stage"
IMAGE="build/${APP_NAME}-${VERSION}.dmg"
rm -rf "$STAGE" "$IMAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$IMAGE" >/dev/null
rm -rf "$STAGE"
cp -f "$IMAGE" "build/${APP_NAME}.dmg"

echo "version: $VERSION ($BUILD_NUMBER)"
echo "disk image: $IMAGE ($(du -h "$IMAGE" | cut -f1))"
echo "release asset: build/${APP_NAME}.dmg"
shasum -a 256 "$IMAGE" "build/${APP_NAME}.dmg"
