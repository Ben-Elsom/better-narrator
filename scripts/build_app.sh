#!/bin/zsh
# Builds Better Narrator and installs it in /Applications.
#
#   scripts/build_app.sh            build + install
#   scripts/build_app.sh --no-install
#
# Needs: Apple's Command Line Tools, uv (for the voice engine's Python), and the
# Kokoro model files in kokoro_test/models (see README).
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
APP_NAME="Better_Narrator"
APP="$BUILD/$APP_NAME.app"
SUPPORT="$HOME/Library/Application Support/Better Narrator"
MODEL_SRC="$ROOT/kokoro_test/models/timestamped/model.onnx"
VOICES_SRC="$ROOT/kokoro_test/models/voices-v1.0.bin"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

cd "$ROOT"
mkdir -p "$BUILD/obj" "$BUILD/vfs"

# Some Command Line Tools installs keep a stale module map from an older version
# that breaks Swift builds ("redefinition of module 'SwiftBridging'"). Hide it.
: > "$BUILD/vfs/empty.modulemap"
cat > "$BUILD/vfs/overlay.yaml" <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file",
  "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap",
  "external-contents": "$BUILD/vfs/empty.modulemap" } ] }
EOF
VFS=(-vfsoverlay "$BUILD/vfs/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$BUILD/vfs/overlay.yaml")

echo "▸ Compiling"
clang -c -fobjc-arc -O2 -mmacosx-version-min=14.0 -I Sources/TouchBarPrivate/include \
  Sources/TouchBarPrivate/TouchBarPrivate.m -o "$BUILD/obj/TouchBarPrivate.o"
swiftc -O -target x86_64-apple-macos14.0 -enable-bare-slash-regex "${VFS[@]}" \
  -import-objc-header Sources/TouchBarPrivate/include/TouchBarPrivate.h \
  Sources/BetterNarrator/*.swift "$BUILD/obj/TouchBarPrivate.o" \
  -framework Cocoa -framework AVFoundation -framework MediaPlayer -framework Carbon \
  -o "$BUILD/obj/BetterNarrator"

echo "▸ Drawing icons"
swiftc -O "${VFS[@]}" scripts/make_icons.swift -o "$BUILD/obj/make_icons"
"$BUILD/obj/make_icons" "$ROOT/Resources" >/dev/null
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/Resources/AppIcon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ROOT/Resources/AppIcon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"

echo "▸ Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine" "$APP/Contents/Resources/models"
cp "$BUILD/obj/BetterNarrator" "$APP/Contents/MacOS/BetterNarrator"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/MenuBarIcon.png" "$ROOT/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/"
cp "$ROOT/engine/narrator_engine.py" "$APP/Contents/Resources/engine/"
cp "$MODEL_SRC" "$APP/Contents/Resources/models/kokoro-timestamped.onnx"
cp "$VOICES_SRC" "$APP/Contents/Resources/models/voices-v1.0.bin"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.betternarrator</string>
  <key>CFBundleName</key><string>Better Narrator</string>
  <key>CFBundleDisplayName</key><string>Better Narrator</string>
  <key>CFBundleExecutable</key><string>BetterNarrator</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Speech by Kokoro-82M (Apache 2.0).</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>app.betternarrator</string>
    <key>CFBundleURLSchemes</key><array><string>betternarrator</string></array>
  </dict></array>
</dict>
</plist>
EOF
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "▸ Voice engine (Python + Kokoro) in $SUPPORT"
mkdir -p "$SUPPORT"
if [[ ! -x "$SUPPORT/engine-venv/bin/python" ]]; then
  uv venv --python 3.12 "$SUPPORT/engine-venv" -q
fi
uv pip install --python "$SUPPORT/engine-venv/bin/python" -q "kokoro-onnx==0.6.1"

if [[ $INSTALL == 1 ]]; then
  echo "▸ Installing to /Applications"
  osascript -e 'tell application id "app.betternarrator" to quit' >/dev/null 2>&1 || true
  pkill -x BetterNarrator 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME.app" >/dev/null 2>&1 || true
  echo "✓ Installed /Applications/$APP_NAME.app"
else
  echo "✓ Built $APP"
fi
