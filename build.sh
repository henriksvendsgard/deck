#!/bin/zsh
# Builds Deck.app into build/.
#   ./build.sh           build only
#   ./build.sh install   build, install to /Applications and launch
#   ./build.sh release   build and zip to build/Deck.zip (for GitHub Releases)
set -e
cd "$(dirname "$0")"
APP=build/Deck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Universal binary: Apple Silicon + Intel.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14 \
    Sources/main.swift -o build/Deck-$arch
done
lipo -create build/Deck-arm64 build/Deck-x86_64 -output "$APP/Contents/MacOS/Deck"
rm build/Deck-arm64 build/Deck-x86_64
codesign --force --sign - "$APP"
echo "Built: $APP"

case "$1" in
  install)
    pkill -TERM -x Deck 2>/dev/null && sleep 1 || true
    # One-time cleanup of the old name.
    pkill -TERM -x Vindusbytter 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Vindusbytter.app
    rm -rf /Applications/Deck.app
    cp -R "$APP" /Applications/
    open /Applications/Deck.app
    echo "Installed: /Applications/Deck.app"
    ;;
  release)
    rm -f build/Deck.zip
    ditto -c -k --keepParent "$APP" build/Deck.zip
    echo "Zipped: build/Deck.zip"
    ;;
esac
