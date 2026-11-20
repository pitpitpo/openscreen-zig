cask "openscreen-zig" do
  version "1.0.0"
  sha256 :no_check # Updated automatically upon tagged release

  url "https://github.com/getopenscreen/openscreen/releases/download/v#{version}/OpenScreen-macOS-universal.dmg"
  name "OpenScreen"
  desc "High-Performance Screen Recorder & Native Video Editor"
  homepage "https://github.com/getopenscreen/openscreen"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "OpenScreen.app"
  binary "#{appdir}/OpenScreen.app/Contents/MacOS/openscreen", target: "openscreen"

  zap trash: [
    "~/Library/Application Support/OpenScreen",
    "~/Library/Preferences/org.openscreen.openscreen.plist",
    "~/Library/Saved Application State/org.openscreen.openscreen.savedState",
  ]
end
