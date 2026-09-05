#!/bin/bash
#
# Builds MagicMouseGestures.app and the mmg-probe CLI.
#
# Firma con una identidad estable si existe, y si no, ad-hoc.
#
# No es un detalle de empaquetado. El «requisito designado» de un binario firmado
# ad-hoc es su propio hash, así que cada compilación produce una identidad nueva
# y macOS invalida Accesibilidad y Monitorización de entrada sin decir nada: la
# fila sigue en Ajustes, con su nombre, y activarla no sirve de nada porque ya no
# corresponde a ese binario. Con un certificado estable el requisito pasa a ser el
# certificado y la concesión sobrevive.
#
#   ./scripts/crear-identidad-de-firma.sh    ← una vez, y se acabó el problema

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

# Los dos idiomas. Van como .lproj dentro del bundle en vez de como recurso de
# SwiftPM porque este .app se monta a mano: `Bundle.main` los encuentra aquí sin
# que haya que arrastrar además el bundle de recursos que genera SwiftPM.
for LPROJ in Resources/*.lproj; do
    cp -R "${LPROJ}" "${APP}/Contents/Resources/"
done

# El icono se dibuja en código (Sources/MagicMouseKit/AppIcon.swift) y se
# convierte aquí. Así no hay PNG que mantener sincronizado con nada.
echo "→ Dibujando el icono…"
ICONSET="${BUILD_DIR}/AppIcon.iconset"
rm -rf "${ICONSET}"
"${BIN_DIR}/mmg-probe" --appicon "${ICONSET}" >/dev/null
iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET}"

# Copying over an existing binary in place invalidates its ad-hoc signature on
# arm64, and macOS then SIGKILLs it at launch — a silent 137 with no output at
# all, even for --help. Remove first, then re-sign.
rm -f "${BUILD_DIR}/mmg-probe"
cp "${BIN_DIR}/mmg-probe" "${BUILD_DIR}/mmg-probe"

IDENTIDAD="MagicMouseGestures Self-Signed"
if [ "${MMG_FIRMA:-}" = "adhoc" ]; then
    # Salida de emergencia: firma ad-hoc a propósito, sin tocar el llavero. Para
    # CI, para una máquina ajena, y para cuando el diálogo del llavero se pone
    # tozudo y hace falta compilar igual.
    FIRMA="-"
    echo "→ Firmando ad-hoc (MMG_FIRMA=adhoc)…"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTIDAD}"; then
    FIRMA="${IDENTIDAD}"
    echo "→ Firmando con «${IDENTIDAD}»…"
    echo "   (si se queda parado aquí, hay un diálogo del llavero esperando:"
    echo "    la respuesta correcta es «Permitir siempre», no «Permitir»)"
else
    FIRMA="-"
    echo "→ Firmando ad-hoc (sin identidad estable)…"
    echo "   Los permisos se invalidarán en cada compilación. Para arreglarlo:"
    echo "   ./scripts/crear-identidad-de-firma.sh"
fi

firmar() {
    codesign --force --sign "$1" --identifier "${BUNDLE_ID}" "${APP}" 2>&1 &&
    codesign --force --sign "$1" --identifier "${BUNDLE_ID}.probe" "${BUILD_DIR}/mmg-probe" 2>&1
}

# Nunca dejar pasar un fallo de firma en silencio: el .app se quedaría con la
# firma que trae `swift build` y macOS le negaría los permisos sin decir por qué.
# Ya pasó, con `errSecInternalComponent` y salida 0.
if ! firmar "${FIRMA}" >/dev/null; then
    if [ "${FIRMA}" != "-" ]; then
        echo "⚠️  No se pudo firmar con «${IDENTIDAD}»." >&2
        echo "   Suele ser que el llavero no autoriza la clave a codesign." >&2
        echo "   Se arregla una vez, desde una terminal de verdad:" >&2
        echo "     ./scripts/autorizar-firma.sh" >&2
        echo "   Mientras tanto, se firma ad-hoc y los permisos habrá que" >&2
        echo "   volver a concederlos tras cada compilación." >&2
        echo >&2
        FIRMA="-"
        firmar "-" >/dev/null || { echo "✗ Tampoco se pudo firmar ad-hoc." >&2; exit 1; }
    else
        echo "✗ No se pudo firmar." >&2
        exit 1
    fi
fi

# «Firmado» y «firmado con lo que pedimos» no son lo mismo: comprobarlo.
codesign --verify --strict "${APP}"
if [ "${FIRMA}" != "-" ] && codesign -d -r- "${APP}" 2>&1 | grep -q "cdhash"; then
    echo "✗ El requisito designado sigue atado al hash del binario:" >&2
    codesign -d -r- "${APP}" 2>&1 | tail -1 >&2
    echo "  Los permisos se invalidarán en la próxima compilación." >&2
    exit 1
fi

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
if [ "${FIRMA}" = "-" ]; then
    echo "Firmado ad-hoc: si ya se los habías concedido a una compilación anterior,"
    echo "quítalos y vuelve a añadirlos, porque la identidad del binario acaba de"
    echo "cambiar. Para que dejen de caerse en cada compilación:"
    echo "  ./scripts/crear-identidad-de-firma.sh   (y después autorizar-firma.sh)"
else
    echo "Firmado con identidad estable: los permisos concedidos sobreviven a las"
    echo "próximas compilaciones. Solo hay que concederlos esta vez."
fi
