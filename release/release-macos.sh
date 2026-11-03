#!/bin/bash
# Builds, signs (Developer ID), notarizes and staples YggApp for macOS, and
# packages it as a DMG. Used by .github/workflows/release-macos.yml; also runs
# locally (notarization is skipped when Apple ID credentials are not set).
#
# Required:
#   PROFILE_APP       Developer ID provisioning profile for com.prietus.yggapp.mac
#   PROFILE_TUNNEL    Developer ID provisioning profile for com.prietus.yggapp.mac.tunnel
# Optional:
#   VERSION           marketing version (default 0.1.0)
#   BUILD_NUMBER      build number; must increase for macOS to update the extension (default 1)
#   SIGN_IDENTITY     codesign identity (default: the Developer ID Application cert)
#   KEYCHAIN          keychain holding the identity (CI uses a temporary one)
#   APPLE_ID, APPLE_APP_PASSWORD   Apple ID + app-specific password for notarytool
#
# The Network Extension / System Extension entitlements are restricted: macOS
# only honours them when a matching Developer ID provisioning profile is
# embedded, which is why the profiles are needed on top of the certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID=LFTD9T269J
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
SIGN_IDENTITY=${SIGN_IDENTITY:-"Developer ID Application: carlos prieto ortiz ($TEAM_ID)"}
: "${PROFILE_APP:?set PROFILE_APP to the app's Developer ID provisioning profile}"
: "${PROFILE_TUNNEL:?set PROFILE_TUNNEL to the extension's Developer ID provisioning profile}"

OUT=build/release
DMG="$OUT/YggApp-$VERSION.dmg"
KC_ARGS=()
[ -n "${KEYCHAIN:-}" ] && KC_ARGS=(--keychain "$KEYCHAIN")
NOTARIZE=0
[ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && NOTARIZE=1

step() { printf '\n== %s\n' "$*"; }

step "yggkit (Go core)"
./build-yggkit.sh

step "Xcode project"
xcodegen generate --quiet

step "Build YggApp $VERSION ($BUILD_NUMBER), unsigned"
rm -rf "$OUT/dd" "$OUT/app" "$OUT/dmg" "$DMG"
mkdir -p "$OUT/app"
# TeamIdentifierPrefix is normally filled in by signing; set it so the
# extension's NEMachServiceName gets the team prefix in an unsigned build.
if ! xcodebuild build -project YggApp.xcodeproj -scheme YggAppMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$OUT/dd" \
  CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM="$TEAM_ID" TeamIdentifierPrefix="$TEAM_ID." \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" > "$OUT/build.log" 2>&1; then
  grep -E ': error: ' "$OUT/build.log" >&2 || tail -40 "$OUT/build.log" >&2
  echo "xcodebuild failed; full log: $OUT/build.log" >&2
  exit 1
fi
grep -E '\*\* BUILD SUCCEEDED \*\*' "$OUT/build.log"
ditto "$OUT/dd/Build/Products/Release/YggApp.app" "$OUT/app/YggApp.app"
APP="$OUT/app/YggApp.app"
EXT="$APP/Contents/Library/SystemExtensions/com.prietus.yggapp.mac.tunnel.systemextension"
[ -d "$EXT" ] || { echo "system extension missing from app bundle" >&2; exit 1; }

MACH=$(/usr/libexec/PlistBuddy -c 'Print NetworkExtension:NEMachServiceName' "$EXT/Contents/Info.plist")
[ "$MACH" = "$TEAM_ID.com.prietus.yggapp.mac.tunnel" ] || { echo "bad NEMachServiceName: $MACH" >&2; exit 1; }

step "Sign with $SIGN_IDENTITY"
cp "$PROFILE_TUNNEL" "$EXT/Contents/embedded.provisionprofile"
cp "$PROFILE_APP" "$APP/Contents/embedded.provisionprofile"
sign() { codesign --force --options runtime --timestamp ${KC_ARGS[@]+"${KC_ARGS[@]}"} --sign "$SIGN_IDENTITY" "$@"; }
sign --entitlements release/YggTunnel.entitlements "$EXT"   # inside-out: extension first
sign --entitlements release/YggApp.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

notarize() {
  local file=$1 result id status
  result=$(xcrun notarytool submit "$file" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" \
    --team-id "$TEAM_ID" --wait --timeout 30m --output-format json)
  id=$(plutil -extract id raw - <<<"$result")
  status=$(plutil -extract status raw - <<<"$result")
  echo "notarization $id: $status"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID" >&2 || true
    exit 1
  fi
}

if [ $NOTARIZE = 1 ]; then
  step "Notarize app"
  ditto -c -k --keepParent "$APP" "$OUT/YggApp.zip"
  notarize "$OUT/YggApp.zip"
  xcrun stapler staple "$APP"
else
  step "Skipping notarization (APPLE_ID / APPLE_APP_PASSWORD not set)"
fi

step "DMG"
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/YggApp.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "YggApp $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG"
codesign --force --timestamp ${KC_ARGS[@]+"${KC_ARGS[@]}"} --sign "$SIGN_IDENTITY" "$DMG"

if [ $NOTARIZE = 1 ]; then
  step "Notarize DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi

step "Done"
ls -lh "$DMG"
