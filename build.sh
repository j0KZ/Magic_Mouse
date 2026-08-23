#!/bin/bash
#
# Builds MagicMouseGestures.app and the mmg-probe CLI.
#
# The app is ad-hoc codesigned on purpose: an unsigned binary gets a new identity
# every build, so macOS forgets the Accessibility permission each time and you end
# up re-granting it forever.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MagicMouseGestures"
BUNDLE_ID="dev.j0kz.magicmousegestures"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"

echo "→ Compilando (release)…"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"

echo "→ Montando ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

cp "${BIN_DIR}/mmg-probe" "${BUILD_DIR}/mmg-probe"

echo "→ Firmando ad-hoc…"
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"

echo
echo "Listo."
echo
echo "  Diagnóstico primero:   ./${BUILD_DIR}/mmg-probe"
echo "  Instalar la app:       cp -r ${APP} /Applications/"
echo
echo "Después de instalar, ábrela y concede Accesibilidad cuando lo pida."
echo "Si ya la habías concedido a una compilación anterior, quítala y vuelve a"
echo "añadirla: la identidad del binario cambia al recompilar."
