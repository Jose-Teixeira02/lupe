#!/bin/zsh
# Builds Lupe.app into ./build (release by default).
#   scripts/build-app.sh            build ./build/Lupe.app
#   scripts/build-app.sh --install  also copy it to ~/Applications and open it
#   scripts/build-app.sh --debug    debug build (faster to compile)
#
# Signing: uses a "Lupe Dev" code-signing certificate from your keychain if you created one
# (keeps macOS permissions across rebuilds — see README), otherwise signs ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case $arg in
    --install) INSTALL=1 ;;
    --debug) CONFIG=debug ;;
  esac
done

echo "▸ Building ($CONFIG)…"
swift build -c $CONFIG --product Lupe 2>&1 | grep -E "error:|warning: unre|Compiling|Build complete" | sed -E 's/\x1b\[[0-9;]*m//g' || true
BIN="$(swift build -c $CONFIG --product Lupe --show-bin-path)/Lupe"
[[ -x "$BIN" ]] || { echo "Build failed"; exit 1; }

APP=build/Lupe.app
VERSION=0.1.0
BUILD_NUMBER=$(date +%Y%m%d%H%M)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lupe"
cp -R packs "$APP/Contents/Resources/packs"

# App icon (re-rendered when the mark's source changes).
ICON_SRC=Sources/Lupe/Onboarding/Onboarding.swift
if [[ ! -f build/AppIcon.icns || "$ICON_SRC" -nt build/AppIcon.icns ]]; then
  echo "▸ Rendering icon…"
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  "$BIN" --icon build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lupe</string>
  <key>CFBundleDisplayName</key><string>Lupe</string>
  <key>CFBundleIdentifier</key><string>local.lupe.Lupe</string>
  <key>CFBundleExecutable</key><string>Lupe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 José Teixeira</string>
  <key>NSScreenCaptureUsageDescription</key><string>Lupe reads the words on your screen, on this Mac only, to translate them and help you learn.</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Translate with Lupe</string></dict>
      <key>NSMessage</key><string>translateService</string>
      <key>NSPortName</key><string>Lupe</string>
      <key>NSSendTypes</key><array><string>NSStringPboardType</string><string>public.utf8-plain-text</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
  </array>
</dict>
</plist>
PLIST

IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Lupe Dev"; then
  IDENTITY="Lupe Dev"
fi
echo "▸ Signing ($([[ $IDENTITY == - ]] && echo ad hoc || echo $IDENTITY))…"
codesign --force --deep --sign "$IDENTITY" --identifier local.lupe.Lupe "$APP"
echo "✓ Built $APP"

if [[ $INSTALL == 1 ]]; then
  mkdir -p ~/Applications
  pkill -x Lupe 2>/dev/null || true
  rm -rf ~/Applications/Lupe.app
  cp -R "$APP" ~/Applications/Lupe.app
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  open ~/Applications/Lupe.app
  echo "✓ Installed to ~/Applications/Lupe.app and launched (look for the magnifier in the menu bar)"
fi
