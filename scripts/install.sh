#!/bin/zsh
# Compila WarpCaos y lo instala en ~/Applications (aparece en Spotlight y Launchpad).
# Uso: ./scripts/install.sh [--no-build]
set -e
cd "$(dirname "$0")/.."
[[ "$1" == "--no-build" ]] || ./scripts/make_app.sh
DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/WarpCaos.app"
ditto build/WarpCaos.app "$DEST/WarpCaos.app"
echo "Instalado: $DEST/WarpCaos.app"
