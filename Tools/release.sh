#!/bin/zsh
# Publishes a new Deck release and updates the Homebrew tap.
#   Tools/release.sh 1.2 "What's new in this release"
#
# 1. Bumps the version in Info.plist, commits and pushes
# 2. Builds build/Deck.zip and creates the GitHub release vX.Y
# 3. Updates packaging/homebrew/deck.rb (version + sha256) and pushes it
#    to github.com/henriksvendsgard/homebrew-tap
set -e
cd "$(dirname "$0")/.."

VERSION="$1"
NOTES="$2"
OWNER=henriksvendsgard
if [[ -z "$VERSION" || -z "$NOTES" ]]; then
  echo "Usage: Tools/release.sh <version> <release notes>" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first." >&2
  exit 1
fi

# Always act as the personal account, whatever gh account is active.
export GH_TOKEN=$(gh auth token -u $OWNER)

# 1. Version bump
PB=/usr/libexec/PlistBuddy
BUILD=$(( $($PB -c "Print :CFBundleVersion" Info.plist) + 1 ))
$PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Info.plist
git commit -qam "Release v$VERSION"
git push -q

# 2. Build and publish
./build.sh release
gh release create "v$VERSION" build/Deck.zip --repo $OWNER/deck --target main \
  --title "Deck $VERSION" --notes "$NOTES

### Install or update
\`\`\`bash
brew install --cask $OWNER/tap/deck     # first time
brew upgrade --cask deck                # update
\`\`\`
Or download \`Deck.zip\` below. See the [README](https://github.com/$OWNER/deck#install)."

# 3. Homebrew tap. Hash the uploaded asset so the cask matches exactly.
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/Deck.zip" "https://github.com/$OWNER/deck/releases/download/v$VERSION/Deck.zip"
SHA=$(shasum -a 256 "$TMP/Deck.zip" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" packaging/homebrew/deck.rb
git commit -qam "Update Homebrew cask to v$VERSION"
git push -q

git clone -q "https://github.com/$OWNER/homebrew-tap.git" "$TMP/tap"
mkdir -p "$TMP/tap/Casks"
cp packaging/homebrew/deck.rb "$TMP/tap/Casks/deck.rb"
cp packaging/homebrew/README.md "$TMP/tap/README.md"
git -C "$TMP/tap" add -A
git -C "$TMP/tap" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
  commit -qm "deck $VERSION"
git -C "$TMP/tap" -c credential.helper= \
  -c "credential.helper=!f() { test \"\$1\" = get || exit 0; echo username=x-access-token; echo password=\$GH_TOKEN; }; f" \
  push -q
rm -rf "$TMP"

echo "Released Deck $VERSION: https://github.com/$OWNER/deck/releases/tag/v$VERSION"
