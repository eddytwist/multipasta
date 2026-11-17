#!/bin/zsh
# Builds Multipasta in Release (Apple Silicon and Intel), signs it and packs it into a disk image for a GitHub release.
# Usage: scripts/build-dmg.sh
#   SIGN_IDENTITY  codesign identity; "-" (the default) signs ad-hoc, which is enough to run the app
#   SIGN_TIMESTAMP set to "none" for a self-signed identity (no Apple timestamp)
#                  after Privacy & Security -> Open Anyway
#   DEVELOPER_DIR  Xcode to build with; defaults to /Applications/Xcode.app when xcode-select points
#                  to the Command Line Tools
#   DERIVED_DATA   xcodebuild derived data folder (default: build/dd-dmg)
#   SPARKLE_KEY_FILE  Sparkle's private EdDSA key for in-app updates
#                  (default: ~/.config/sparkle/multipasta-ed25519.key; never commit it)
#   RELEASE_NOTES  Markdown file shown in the update window (optional)
#   ALLOW_NO_FEED  set to 1 when no feed is published yet (the first release with one)
# Output: build/Multipasta-<version>.dmg, a copy named build/Multipasta.dmg (the release asset
# name) and build/appcast.xml, the update feed. Attach both Multipasta.dmg and appcast.xml to the
# GitHub release: the app reads releases/latest/download/appcast.xml (SUFeedURL in Info.plist).
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

# A feed left from an earlier run must never sit next to a new disk image.
rm -f build/appcast.xml

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

# Re-sign with the hardened runtime: ad-hoc by default, or with SIGN_IDENTITY. Sparkle's helpers
# are signed one by one, inside out, as Sparkle documents (no --deep: it would give them the app's
# entitlements and drop the Downloader service's own).
SIGN_ARGS=(--force --options runtime -s "$SIGN_IDENTITY")
# A secure timestamp needs an Apple-issued certificate; ad-hoc and self-signed identities skip it.
if [[ "$SIGN_IDENTITY" == "-" || "${SIGN_TIMESTAMP:-}" == "none" ]]; then
  SIGN_ARGS+=(--timestamp=none)
else
  SIGN_ARGS+=(--timestamp)
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "Sparkle.framework is missing from $APP" >&2; exit 1; }
# Sparkle's license asks for its notice in every copy; the framework doesn't carry one.
cp -f "$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$SPARKLE"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
# Without this entitlement the hardened runtime refuses Sparkle.framework (a self-signed or ad-hoc
# signature has no Team ID) and the app crashes at launch.
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.cs.disable-library-validation" \
  || { echo "$APP lacks the disable-library-validation entitlement" >&2; exit 1; }
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

# The update feed: one item, the version just built. Sparkle checks the feed's and the disk image's
# EdDSA signatures against SUPublicEDKey before it installs anything.
# Only a build signed with a certificate can go into the feed: an ad-hoc one has a designated
# requirement made of its own hash, so every user would lose Accessibility after updating.
if [[ "$SIGN_IDENTITY" == "-" ]] || ! codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf'; then
  echo "version: $VERSION ($BUILD_NUMBER), ad-hoc signed: no update feed (set SIGN_IDENTITY for a release)"
  echo "disk image: $IMAGE"
  exit 0
fi
# Sparkle compares build numbers: a release whose CURRENT_PROJECT_VERSION wasn't raised would
# never reach anyone.
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")"
PUBLISHED_BUILD="$(curl -fsSL --max-time 20 "$FEED_URL" 2>/dev/null | sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | head -1 || true)"
if [[ -z "$PUBLISHED_BUILD" ]]; then
  # Only the first release with a feed (0.4.0) has nothing to compare with.
  [[ "${ALLOW_NO_FEED:-}" == "1" ]] || { echo "can't read the published feed at $FEED_URL; set ALLOW_NO_FEED=1 for the first feed" >&2; exit 1; }
  echo "warning: no published feed to compare the build number with (ALLOW_NO_FEED=1)" >&2
elif (( BUILD_NUMBER <= PUBLISHED_BUILD )); then
  echo "build number $BUILD_NUMBER is not above the published $PUBLISHED_BUILD; raise CURRENT_PROJECT_VERSION" >&2
  exit 1
fi
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-$HOME/.config/sparkle/multipasta-ed25519.key}"
[[ -r "$SPARKLE_KEY_FILE" ]] || { echo "Sparkle key not found at $SPARKLE_KEY_FILE; set SPARKLE_KEY_FILE" >&2; exit 1; }
ENCLOSURE_ATTRS="$("$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "build/${APP_NAME}.dmg")"
[[ "$ENCLOSURE_ATTRS" == *'sparkle:edSignature="'* ]] || { echo "sign_update failed: $ENCLOSURE_ATTRS" >&2; exit 1; }
RELEASE_URL="https://github.com/eddytwist/multipasta/releases/tag/v${VERSION}"
DOWNLOAD_URL="https://github.com/eddytwist/multipasta/releases/download/v${VERSION}/${APP_NAME}.dmg"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
DESCRIPTION=""
if [[ -n "${RELEASE_NOTES:-}" ]]; then
  [[ -r "$RELEASE_NOTES" ]] || { echo "release notes not found at $RELEASE_NOTES" >&2; exit 1; }
  # CDATA can't contain its own terminator.
  NOTES="$(sed 's/]]>/]]]]><![CDATA[>/g' "$RELEASE_NOTES")"
  DESCRIPTION="      <description sparkle:format=\"markdown\"><![CDATA[${NOTES}]]></description>"
fi
cat > build/appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${APP_NAME}</title>
    <link>https://github.com/eddytwist/multipasta</link>
    <item>
      <title>${APP_NAME} ${VERSION}</title>
      <link>${RELEASE_URL}</link>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>${RELEASE_URL}</sparkle:fullReleaseNotesLink>
${DESCRIPTION}
      <enclosure url="${DOWNLOAD_URL}" type="application/octet-stream" ${ENCLOSURE_ATTRS} />
    </item>
  </channel>
</rss>
APPCAST
xmllint --noout build/appcast.xml
# SURequireSignedFeed: the feed carries its own signature, so a changed feed is refused too.
"$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" build/appcast.xml >/dev/null
"$SPARKLE_BIN/sign_update" --verify --ed-key-file "$SPARKLE_KEY_FILE" build/appcast.xml >/dev/null \
  || { echo "the signed appcast doesn't verify" >&2; exit 1; }
"$SPARKLE_BIN/sign_update" --verify --ed-key-file "$SPARKLE_KEY_FILE" "build/${APP_NAME}.dmg" \
  "$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$ENCLOSURE_ATTRS")" >/dev/null \
  || { echo "the disk image signature doesn't verify" >&2; exit 1; }
xmllint --noout build/appcast.xml

echo "version: $VERSION ($BUILD_NUMBER)"
echo "disk image: $IMAGE ($(du -h "$IMAGE" | cut -f1))"
echo "release assets: build/${APP_NAME}.dmg, build/appcast.xml (tag: v${VERSION})"
shasum -a 256 "$IMAGE" "build/${APP_NAME}.dmg"
