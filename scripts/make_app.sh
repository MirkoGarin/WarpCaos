#!/bin/zsh
# Empaqueta WarpCaos como build/WarpCaos.app (sin Xcode).
# Binario universal (arm64 + x86_64).
set -e
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)

# Sin Xcode no hay XCBuild (--arch con dos arquitecturas), así que se compila cada una por separado y se unen con lipo.
swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path .build-x86_64
swift build -c release --triple arm64-apple-macosx13.0 --scratch-path .build-arm64
mkdir -p build
BIN="build/WarpCaos-universal"
lipo -create -output "$BIN" \
    .build-x86_64/x86_64-apple-macosx/release/WarpCaos \
    .build-arm64/arm64-apple-macosx/release/WarpCaos
echo "Binario universal: $(lipo -archs "$BIN")"

APP="build/WarpCaos.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WarpCaos"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>WarpCaos</string>
<key>CFBundleDisplayName</key><string>WarpCaos</string>
<key>CFBundleIdentifier</key><string>com.mirko.warpcaos</string>
<key>CFBundleExecutable</key><string>WarpCaos</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${VERSION}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSAppTransportSecurity</key><dict>
  <key>NSAllowsArbitraryLoadsForMedia</key><true/>
</dict>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Proyecto WarpCaos</string>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>LSHandlerRank</key><string>Owner</string>
  <key>LSItemContentTypes</key><array><string>com.mirko.warpcaos.project</string></array>
</dict></array>
<key>UTExportedTypeDeclarations</key><array><dict>
  <key>UTTypeIdentifier</key><string>com.mirko.warpcaos.project</string>
  <key>UTTypeDescription</key><string>Proyecto WarpCaos</string>
  <key>UTTypeConformsTo</key><array><string>public.json</string></array>
  <key>UTTypeTagSpecification</key><dict>
    <key>public.filename-extension</key><array><string>mapproj</string></array>
  </dict>
</dict></array>
</dict></plist>
PLIST

codesign --force --sign - "$APP"
echo "OK: $APP (v${VERSION})"
