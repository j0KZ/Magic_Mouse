#!/bin/bash
#
# Crea un certificado autofirmado para firmar MagicMouseGestures, una sola vez.
#
# Por qué existe: con firma ad-hoc, el «requisito designado» del binario es su
# propio hash, así que cada recompilación produce una identidad nueva y macOS
# invalida los permisos de Accesibilidad y Monitorización de entrada sin decir
# nada. La fila sigue en la lista de Ajustes, con su nombre, y activarla no hace
# nada porque ya no corresponde a ese binario. Con un certificado estable el
# requisito pasa a ser el certificado, y la concesión sobrevive a las
# recompilaciones.
#
# Se ejecuta una vez. Pide la contraseña del llavero.

set -euo pipefail

NOMBRE="MagicMouseGestures Self-Signed"
LLAVERO="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${NOMBRE}"; then
    echo "✓ La identidad «${NOMBRE}» ya existe. No hay nada que hacer."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "→ Generando el certificado…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" \
    -subj "/CN=${NOMBRE}" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Con contraseña, aunque sea de usar y tirar: `security import` no traga un
# PKCS#12 sin contraseña y falla con «MAC verification failed», que suena a
# corrupción y no lo es.
CLAVE="mmg-$(date +%s)"

openssl pkcs12 -export -out "${TMP}/identidad.p12" \
    -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
    -name "${NOMBRE}" -passout "pass:${CLAVE}" 2>/dev/null

echo "→ Importando al llavero (puede pedir la contraseña)…"
security import "${TMP}/identidad.p12" -k "${LLAVERO}" -P "${CLAVE}" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "→ Marcándolo como de confianza para firmar código…"
security add-trusted-cert -r trustRoot -p codeSign -k "${LLAVERO}" "${TMP}/cert.pem"

echo "→ Dejando que codesign use la clave sin preguntar cada vez…"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "${LLAVERO}" >/dev/null 2>&1 || \
    echo "   (no se pudo; codesign pedirá permiso la primera vez, dale a «Permitir siempre»)"

echo
if security find-identity -v -p codesigning | grep -q "${NOMBRE}"; then
    echo "✓ Listo. ./build.sh la usará a partir de ahora."
    echo
    echo "  Como la identidad del binario cambia AHORA por última vez, hay que"
    echo "  volver a conceder los dos permisos una vez más:"
    echo
    echo "    tccutil reset ListenEvent dev.j0kz.magicmousegestures"
    echo "    tccutil reset Accessibility dev.j0kz.magicmousegestures"
else
    echo "✗ La identidad no aparece como válida. build.sh seguirá con firma ad-hoc."
    exit 1
fi
