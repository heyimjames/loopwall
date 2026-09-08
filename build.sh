#!/bin/sh
# Release build, ad-hoc sign, install to /Applications, relaunch.
set -e
cd "$(dirname "$0")"

command -v xcodegen >/dev/null && xcodegen generate

xcodebuild -project Loopwall.xcodeproj -scheme Loopwall \
  -configuration Release -derivedDataPath build build

osascript -e 'quit app "Loopwall"' 2>/dev/null || true
sleep 1

rm -rf /Applications/Loopwall.app
cp -R build/Build/Products/Release/Loopwall.app /Applications/
codesign --force --deep --sign - /Applications/Loopwall.app

open -a /Applications/Loopwall.app
echo "Loopwall installed and running."
