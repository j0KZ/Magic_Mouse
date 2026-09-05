#!/bin/bash
#
# Autoriza a codesign a usar la clave de firma sin preguntar cada vez.
#
# Sin esto, macOS muestra un diálogo del llavero en CADA proceso nuevo de
# codesign, y `build.sh` se queda esperando una respuesta que puede aparecer
# detrás de otra ventana o en otro escritorio. Con «Permitir siempre» en ese
# diálogo bastaría; esto hace lo mismo desde el terminal, de una vez y sin
# depender de encontrar la ventana.
#
# Pide la contraseña de tu llavero (la de tu usuario del Mac). No se guarda en
# ningún sitio ni se muestra al teclearla.
#
# OJO: hay que ejecutarlo desde una ventana de Terminal de verdad. `security`
# pide la contraseña por el terminal, así que si esto corre sin teclado detrás
# —dentro de un agente, un hook o una tarea en segundo plano— se queda esperando
# para siempre a una respuesta que nadie puede darle.

set -euo pipefail

NOMBRE="MagicMouseGestures Self-Signed"
LLAVERO="${HOME}/Library/Keychains/login.keychain-db"

if ! security find-identity -v -p codesigning | grep -q "${NOMBRE}"; then
    echo "✗ No existe la identidad «${NOMBRE}»."
    echo "  Ejecuta primero: ./scripts/crear-identidad-de-firma.sh"
    exit 1
fi

# Sin `-k`: así la contraseña la pide macOS con su propio diálogo en vez de
# leerla de la entrada estándar. Es más seguro —no pasa por el terminal ni por
# ningún historial— y además funciona cuando esto se ejecuta sin una terminal
# interactiva detrás, que es donde la versión con `read` se quedaba muda.
echo "→ macOS va a pedir tu contraseña en un diálogo. Es para autorizar la clave."
echo

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -l "${NOMBRE}" \
    "${LLAVERO}" >/dev/null

echo "✓ Autorizado. codesign ya no volverá a preguntar."
echo "  Ahora: ./build.sh"
