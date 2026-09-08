#!/bin/sh
# Cut a new Loopwall release: build+notarize the DMG (via dist.sh), sign it
# for Sparkle, prepend an appcast.xml entry, tag, and publish a GitHub
# Release with the DMG attached.
#
# Usage: ./release.sh <marketing-version> <build-number>
#   e.g. ./release.sh 1.1 2
set -e
cd "$(dirname "$0")"

VERSION="$1"
BUILD="$2"
if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
  echo "Usage: ./release.sh <marketing-version> <build-number>"
  echo "  e.g. ./release.sh 1.1 2"
  exit 1
fi

DOT_COUNT="$(echo "$VERSION" | awk -F. '{print NF-1}')"
if [ "$DOT_COUNT" -ge 2 ]; then
  TAG="v$VERSION"
else
  TAG="v$VERSION.0"
fi
DMG_PATH="build/Loopwall.dmg"

echo "==> Bumping MARKETING_VERSION to $VERSION, CURRENT_PROJECT_VERSION to $BUILD…"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml

echo "==> Building, signing, and notarizing (dist.sh)…"
./dist.sh

echo "==> Signing DMG for Sparkle…"
SIG_LINE="$(./tools/sparkle/sign_update "$DMG_PATH")"
ED_SIGNATURE="$(echo "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"

PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
ENCLOSURE_URL="https://github.com/heyimjames/loopwall/releases/download/$TAG/Loopwall.dmg"

echo "==> Prepending appcast.xml entry for $VERSION ($BUILD)…"
NEW_ITEM="    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure
        url=\"$ENCLOSURE_URL\"
        sparkle:edSignature=\"$ED_SIGNATURE\"
        length=\"$LENGTH\"
        type=\"application/octet-stream\" />
    </item>"

awk -v item="$NEW_ITEM" '
  /<channel>/ { print; found=1; next }
  found && /<item>/ && !inserted { print item; inserted=1 }
  { print }
' appcast.xml > appcast.xml.new
mv appcast.xml.new appcast.xml

echo "==> Committing, tagging $TAG, and pushing…"
git add project.yml appcast.xml
git commit -m "Release $TAG"
git tag "$TAG"
git push origin main
git push origin "$TAG"

echo "==> Creating GitHub release…"
gh release create "$TAG" "$DMG_PATH" \
  --title "Loopwall $VERSION" \
  --notes "See README for usage. Auto-updates via Sparkle from this release onward."

echo ""
echo "Done. Released $TAG — Sparkle will pick this up via appcast.xml automatically."
