#!/bin/zsh
# Genera build/WarpCaos-<versión>.dmg con la app y un acceso directo a /Applications.
set -e
cd "$(dirname "$0")/.."
./scripts/make_app.sh
VERSION=$(cat VERSION)
STAGE="build/dmg-stage"
DMG="build/WarpCaos-${VERSION}.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/WarpCaos.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "WarpCaos ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "OK: $DMG"
