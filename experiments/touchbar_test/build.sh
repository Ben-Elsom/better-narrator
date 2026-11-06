#!/bin/zsh
# Builds TouchBarTest.app next to this script.
set -euo pipefail
HERE="${0:A:h}"
APP="$HERE/build/TouchBarTest.app"
rm -rf "$HERE/build"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.betternarrator.touchbartest</string>
  <key>CFBundleName</key><string>TouchBarTest</string>
  <key>CFBundleExecutable</key><string>TouchBarTest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF
clang -fobjc-arc -framework Cocoa -o "$APP/Contents/MacOS/TouchBarTest" "$HERE/TouchBarTest.m"
codesign --force --sign - "$APP"
echo "Built $APP"
