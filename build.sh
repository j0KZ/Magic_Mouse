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

# Copying over an existing binary in place invalidates its ad-hoc signature on
# arm64, and macOS then SIGKILLs it at launch — a silent 137 with no output at
# all, even for --help. Remove first, then re-sign.
rm -f "${BUILD_DIR}/mmg-probe"
cp "${BIN_DIR}/mmg-probe" "${BUILD_DIR}/mmg-probe"

echo "→ Firmando ad-hoc…"
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP}"
codesign --force --sign - --identifier "${BUNDLE_ID}.probe" "${BUILD_DIR}/mmg-probe"

echo
echo "Listo."
echo
echo "  Diagnóstico primero:   ./${BUILD_DIR}/mmg-probe"
echo "  Instalar la app:       cp -r ${APP} /Applications/"
echo
echo "Después de instalar, ábrela y concede los DOS permisos que pide:"
echo "  · Accesibilidad          — para publicar los atajos"
echo "  · Monitorización de entrada — para leer los dedos"
echo
echo "El segundo es el que se olvida, y no falla ruidosamente: sin él la app"
echo "arranca, ve el mouse, y no le llega ni un contacto."
echo
echo "Si ya se los habías concedido a una compilación anterior, quítalos y vuelve"
echo "a añadirlos: la identidad del binario cambia al recompilar."
