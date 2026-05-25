cask "rollpaper" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://api.douglaslassance.me/rollpaper/download/#{version}/aarch64-apple-darwin"
  name "Rollpaper"
  desc "Menu-bar wallpaper rotator"
  homepage "https://github.com/douglaslassance/rollpaper"

  livecheck do
    url "https://api.douglaslassance.me/rollpaper"
    strategy :json do |json|
      json["latest"]
    end
  end

  depends_on macos: ">= :sonoma"

  app "Rollpaper.app"

  zap trash: [
    "~/Library/Application Support/Rollpaper",
    "~/Library/Caches/me.douglaslassance.Rollpaper",
    "~/Library/Preferences/me.douglaslassance.Rollpaper.plist",
  ]
end
