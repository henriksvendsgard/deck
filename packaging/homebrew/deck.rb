cask "deck" do
  version "1.2"
  sha256 "8d5a04371c26b16cff2d775c359e5e8f9f791ddaaf5445ce44f61bb09c904cc0"

  url "https://github.com/henriksvendsgard/deck/releases/download/v#{version}/Deck.zip"
  name "Deck"
  desc "Cmd+Tab window switcher that shows every window"
  homepage "https://github.com/henriksvendsgard/deck"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Deck.app"

  # Deck is not notarized. Remove the quarantine flag before the app is moved
  # into place so macOS doesn't block it.
  preflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "Deck.app"],
                          chdir: ".", writable_paths: ["Deck.app"]
  end

  uninstall quit: "io.github.henriksvendsgard.Deck"

  zap trash: "~/Library/Preferences/io.github.henriksvendsgard.Deck.plist"

  caveats <<~EOS
    Open Deck from Applications. It needs Accessibility access to take over Cmd+Tab:
      System Settings → Privacy & Security → Accessibility → Deck

    After an upgrade, remove the old Deck entry there and add the new one.
  EOS
end
