#!/bin/zsh
# Bygger Vindusbytter.app til build/.
# ./build.sh install  – bygger, installerer i /Applications og starter appen.
set -e
cd "$(dirname "$0")"
APP=build/Vindusbytter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos13 \
  Sources/main.swift -o "$APP/Contents/MacOS/Vindusbytter"
codesign --force --sign - "$APP"
echo "Bygget: $APP"

if [[ "$1" == "install" ]]; then
  pkill -TERM -x Vindusbytter 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Vindusbytter.app
  cp -R "$APP" /Applications/
  open /Applications/Vindusbytter.app
  echo "Installert: /Applications/Vindusbytter.app"
fi
