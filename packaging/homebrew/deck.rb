cask "deck" do
  version "1.1"
  sha256 "1490abcdf8805883213ee3b98e1b4fa61566cb7652c1949f2249db474e57fc90"

  url "https://github.com/henriksvendsgard/deck/releases/download/v#{version}/Deck.zip"
  name "Deck"
  desc "Cmd+Tab window switcher that shows every window"
  homepage "https://github.com/henriksvendsgard/deck"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Deck.app"

  # Deck is not notarized. Remove the quarantine flag so macOS doesn't block it,
  # then (re)start it so an install or upgrade takes effect right away.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Deck.app"]
    system_command "/usr/bin/open", args: ["#{appdir}/Deck.app"]
  end

  uninstall quit: "io.github.henriksvendsgard.Deck"

  zap trash: "~/Library/Preferences/io.github.henriksvendsgard.Deck.plist"

  caveats <<~EOS
    Deck needs Accessibility access to take over Cmd+Tab:
      System Settings → Privacy & Security → Accessibility → Deck

    After an upgrade, remove the old Deck entry there and add the new one.
  EOS
end
