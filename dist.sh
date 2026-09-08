#!/bin/sh
# Archive, sign with Developer ID, notarize, staple, and package Loopwall
# as a DMG for direct distribution (outside the Mac App Store).
#
# Requires a "Developer ID Application" certificate for TEAM_ID in the local
# keychain (Xcode -> Settings -> Accounts -> Manage Certificates -> + ->
# Developer ID Application — the App Store Connect API can't create this
# certificate type, so it's a one-time manual step) and an authenticated
# `asc` CLI profile for notarization.
set -e
cd "$(dirname "$0")"

TEAM_ID="HJJGM6KHY5"
ARCHIVE_PATH="build/Loopwall.xcarchive"
EXPORT_PATH="build/Export"
EXPORT_OPTIONS="build/ExportOptions.plist"
DMG_PATH="build/Loopwall.dmg"
DMG_STAGING="build/dmg-staging"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No 'Developer ID Application' certificate found in the keychain."
  echo "Create one: Xcode -> Settings -> Accounts -> select your team -> Manage Certificates -> + -> Developer ID Application"
  exit 1
fi

command -v xcodegen >/dev/null && xcodegen generate

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$DMG_PATH" "$DMG_STAGING"
mkdir -p build

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
PLIST

echo "==> Archiving with Developer ID signing…"
xcodebuild archive \
  -project Loopwall.xcodeproj -scheme Loopwall -configuration Release \
  -archivePath "$ARCHIVE_PATH" -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  PROVISIONING_PROFILE_SPECIFIER=""

echo "==> Exporting…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP="$EXPORT_PATH/Loopwall.app"

echo "==> Verifying signature…"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority|Timestamp"

echo "==> Zipping for notarization…"
ditto -c -k --keepParent "$APP" "$EXPORT_PATH/Loopwall.zip"

echo "==> Submitting for notarization (can take a few minutes)…"
asc notarization submit --file "$EXPORT_PATH/Loopwall.zip" --wait

echo "==> Stapling ticket to the app…"
xcrun stapler staple "$APP"

echo "==> Building DMG…"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"
# create-dmg wants an empty destination and builds the Applications-folder
# drop link itself (--app-drop-link) — a plain symlink here would collide.
create-dmg \
  --volname "Loopwall" \
  --volicon "dmg-assets/Loopwall.icns" \
  --background "dmg-assets/background.png" \
  --window-size 660 420 \
  --icon-size 128 \
  --text-size 12 \
  --icon "Loopwall.app" 165 200 \
  --app-drop-link 495 200 \
  --hide-extension "Loopwall.app" \
  --no-internet-enable \
  "$DMG_PATH" \
  "$DMG_STAGING"

echo "==> Signing the DMG container…"
codesign --force --sign "Developer ID Application: $TEAM_ID" "$DMG_PATH" 2>/dev/null \
  || codesign --force --sign "Developer ID Application" "$DMG_PATH"

# A notarization ticket is keyed to the exact file's hash. The app was
# already notarized+stapled above, but the DMG wrapper is a different file
# with a different hash — it needs its own notarization pass, or `spctl -t
# install` on the DMG itself reports "Unnotarized Developer ID" even though
# the app inside is fine.
echo "==> Submitting the DMG for notarization (can take a few minutes)…"
asc notarization submit --file "$DMG_PATH" --wait

echo "==> Stapling ticket to the DMG…"
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Done: $DMG_PATH"
echo "Verify with: spctl -a -vvv -t install \"$DMG_PATH\""
