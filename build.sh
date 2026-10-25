#!/bin/bash
# 编译并打包成 奶蛙.app（放在 build/ 下，同时支持 Apple 芯片和 Intel）。
# 用法：./build.sh [安装目录]，例如 ./build.sh /Applications
set -euo pipefail
cd "$(dirname "$0")"
APP="build/奶蛙.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -o "build/Naiwa-$arch" Sources/main.swift \
    -framework AppKit -framework SpriteKit -framework AVFoundation -framework Carbon
done
lipo -create -output "$APP/Contents/MacOS/Naiwa" build/Naiwa-arm64 build/Naiwa-x86_64
cp -R Resources/frames Resources/sounds Resources/menu_icon.png Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>奶蛙</string>
  <key>CFBundleDisplayName</key><string>奶蛙</string>
  <key>CFBundleIdentifier</key><string>io.github.nathanskill.naiwa-mac</string>
  <key>CFBundleExecutable</key><string>Naiwa</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>移植自 22hewang/naiwa-ultimate，PolyForm Noncommercial 1.0.0，禁止商用</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP"
echo "built $APP"
if [ "${1:-}" != "" ]; then
  ditto "$APP" "$1/奶蛙.app"
  echo "installed to $1/奶蛙.app"
fi
