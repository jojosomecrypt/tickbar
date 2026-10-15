#!/bin/bash
# Builds dist/TickBar.app (universal arm64 + x86_64) and dist/TickBar.zip.
#
#   scripts/build_app.sh                      ad-hoc signed (others: System Settings > Privacy & Security > Open Anyway)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=tickbar scripts/build_app.sh    Developer ID signed + notarized (opens cleanly anywhere)
#
# One-time notary setup: xcrun notarytool store-credentials tickbar --apple-id you@x.com --team-id TEAMID
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.1.1}"
BUNDLE_ID="app.tickbar.TickBar"
APP="dist/TickBar.app"

echo "→ Building release binaries"
swift build -c release --arch arm64
swift build -c release --arch x86_64

echo "→ Assembling $APP"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/TickBar" \
  .build/arm64-apple-macosx/release/TickBar .build/x86_64-apple-macosx/release/TickBar

echo "→ Rendering icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
swift scripts/make_icon.swift "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TickBar</string>
  <key>CFBundleDisplayName</key><string>TickBar</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>TickBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
  <key>NSHumanReadableCopyright</key><string>Live prices from Binance.</string>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "→ Signing with $SIGN_IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  echo "→ Ad-hoc signing (no Developer ID set)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

ditto -c -k --keepParent "$APP" dist/TickBar.zip

if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
  echo "→ Notarizing"
  xcrun notarytool submit dist/TickBar.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm dist/TickBar.zip && ditto -c -k --keepParent "$APP" dist/TickBar.zip
  spctl --assess --type execute --verbose "$APP"
fi

echo "✓ $APP  ($(du -sh "$APP" | cut -f1))  and dist/TickBar.zip"
