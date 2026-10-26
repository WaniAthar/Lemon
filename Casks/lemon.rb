cask "lemon" do
  version "0.1.0"
  sha256 "b9b0cb6b96eec466a2e39fd5e46c6edec8e324974571cdb0ed11695bfaf3cfec"

  url "https://github.com/WaniAthar/Lemon/raw/dist/Lemon-#{version}.zip"
  name "Lemon"
  desc "Radial dial of file conversion and editing tools"
  homepage "https://github.com/WaniAthar/Lemon"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Lemon.app"

  zap trash: [
    "~/Library/Application Scripts/com.lemon.Lemon",
    "~/Library/Containers/com.lemon.Lemon",
  ]

  caveats <<~EOS
    Lemon is not notarized yet. On first launch macOS will block it:
    open System Settings > Privacy & Security and click "Open Anyway".
  EOS
end
