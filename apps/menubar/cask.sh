#!/usr/bin/env bash
# Prints the Homebrew cask for ZCBar. The release workflow runs it after it
# uploads the zip, and opens a pull request with the result as Casks/zcbar.rb.
# Usage: cask.sh VERSION SHA256
set -euo pipefail

version=${1:?usage: cask.sh VERSION SHA256}
sha=${2:?usage: cask.sh VERSION SHA256}

cat <<CASK
cask "zcbar" do
  version "${version}"
  sha256 "${sha}"

  url "https://github.com/zoolcoder/zc-workstation/releases/download/v#{version}/ZCBar_#{version}.zip"
  name "ZCBar"
  desc "Menu bar app and Mac care for zc-workstation"
  homepage "https://zoolcoder.github.io/zc-workstation/"

  depends_on macos: ">= :sonoma"
  depends_on cask: "zoolcoder/zc-workstation/zc-workstation"

  app "ZCBar.app"

  uninstall quit: "dev.zoolcoder.zcbar"

  zap trash: [
    "~/Library/Application Support/ZCBar",
    "~/Library/Preferences/dev.zoolcoder.zcbar.plist",
  ]

  caveats <<~EOS
    ZCBar is signed ad hoc until it is notarised, so macOS blocks the first
    start. Open it once from Finder with Control-click, Open, or run:
      xattr -dr com.apple.quarantine "#{appdir}/ZCBar.app"
  EOS
end
CASK
