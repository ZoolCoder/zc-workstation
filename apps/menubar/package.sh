#!/usr/bin/env bash
# Builds ZCBar and wraps it in an ad-hoc signed .app: a menu bar app, with no
# Dock icon. Usage: package.sh OUT.app; VERSION sets the bundle version.
set -euo pipefail

out=${1:?usage: package.sh OUT.app}
version=${VERSION:-0.0.0-dev}
here=$(cd "$(dirname "$0")" && pwd)

swift build --package-path "$here" -c release
bin=$(swift build --package-path "$here" -c release --show-bin-path)

rm -rf "$out"
mkdir -p "$out/Contents/MacOS"
cp "$bin/ZCBar" "$out/Contents/MacOS/ZCBar"
cat >"$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ZCBar</string>
    <key>CFBundleDisplayName</key><string>ZC Workstation</string>
    <key>CFBundleIdentifier</key><string>dev.zoolcoder.zcbar</string>
    <key>CFBundleExecutable</key><string>ZCBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${version}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>ZoolCoder</string>
</dict>
</plist>
PLIST
# Ad-hoc: enough for this Mac, and for the login item to keep its identity.
codesign --force --sign - --timestamp=none "$out"
echo "built $out ($version)"
