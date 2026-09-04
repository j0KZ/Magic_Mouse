# MagicMouseGestures — arquitectura y uso

Implementación de la **ruta estable** decidida en la
[investigación](01-investigacion-y-factibilidad.md): el gesto en el Magic Mouse
dispara el mismo atajo del sistema que ya usa el trackpad. Sin `DockSwipe`
sintéticos, sin campos de `CGEvent` sin documentar, sin nada que macOS 27
cambiara.

**Objetivo de hardware:** MacBook Pro 14" M5 Pro (Apple Silicon, arm64e) +
Magic Mouse USB-C, macOS 26 Tahoe y macOS 27 Golden Gate.

---

## Cómo está construido

```
Magic Mouse
   │  contactos crudos
   ▼
MultitouchBridge ──── dlopen/dlsym sobre MultitouchSupport.framework
   │                  (nunca llamadas directas: arm64e mata eso con PAC)
   ▼
TouchDecoder ──────── lee 6 campos en offsets fijos de cada contacto de 96 bytes
   │
   ▼
GestureRecognizer ─── ¿exactamente N dedos, un eje dominante, dentro de la ventana?
   │
   ├──▶ ScrollSuppressor ── se traga el scroll que macOS genera por su cuenta
   │                        mientras la mano está apoyada
   ▼
ActionEmitter ─────── publica el atajo real del sistema (Ctrl+↑ y compañía)
```

Alrededor, tres piezas que existen solo para poder responder preguntas sobre el
hardware sin tenerlo delante:

- **`FrameLog`** graba y reproduce frames. Es lo que convierte «parece que va»
  en una medida repetible: ver [`Fixtures/`](../Fixtures/README.md).
- **`Calibrator`** deduce `invertY`, `invertX` y `swipeThreshold` de unos
  cuantos deslizamientos en vez de que los ajustes a ojo.
- **`InputMonitoring`** comprueba el permiso que nadie recuerda. Sin él
  `MTDeviceStart` dice que sí, el dispositivo aparece en la lista, y no llega
  ni un solo contacto.

### Por qué cada pieza es como es

**`MultitouchBridge`** — todo pasa por `dlopen`/`dlsym`. En arm64e, declarar
estos símbolos como `extern` y llamarlos directo revienta con *bus error* por
*pointer authentication*. Tampoco usamos `MTDeviceGetDeviceID`, que tiene una
convención de llamada inestable.

**`TouchDecoder`** — en vez de replicar la struct de C en Swift, donde el
compilador no promete el mismo layout, leemos seis campos en offsets fijos de
cada bloque de 96 bytes. `mmg-probe --raw` vuelca esos bytes para poder
re-verificar los offsets contra cualquier build de macOS.

**`GestureRecognizer`** — una **compuerta de velocidad**, y ese es el corazón
del proyecto. Mide el recorrido dentro de una ventana corta (220 ms), no la
distancia desde el primer contacto. La diferencia no es un detalle de ajuste:
con tres dedos apoyados el 53 % del uso normal, un umbral de distancia pura no
distingue un gesto de la mano moviéndose de sitio, porque acaba recorriendo lo
mismo. En velocidad sí se separan, y con holgura — ver la sección de medidas.

Encima de eso, tres reglas que salieron de mirar grabaciones:

- **Mediana por dedo, no centroide.** Perder uno de tres contactos mueve el
  centroide 0,17 en x él solo, y eso es indistinguible de un barrido.
- **Se dispara con el máximo de dedos del trazo, no con los del frame.** En los
  bordes de la superficie el dedo exterior parpadea; exigir los tres en el
  instante del disparo reduce la zona útil al tercio central.
- **Un disparo por contacto.** Un flick que no se levanta sigue cumpliendo la
  compuerta frame tras frame, y volver arrastrando es un flick perfecto en la
  otra dirección.

**`ScrollSuppressor`** — el problema que identificamos como «el gordo». Con tres
dedos apoyados, el reconocedor nativo ve dos de ellos y empieza a hacer scroll.
No hay forma soportada de decirle a macOS que ignore un dispositivo, así que
interceptamos el scroll con un `CGEventTap` y lo descartamos mientras la mano
está sobre el sensor, más una cola corta para absorber el *momentum* que macOS
manda al levantar los dedos.

**`ActionEmitter`** — para cada acción tiene el atajo de fábrica de Apple como
respaldo, y opcionalmente lee el que tú tengas de verdad en
`com.apple.symbolichotkeys`. Si el ID simbólico no existe o está deshabilitado,
cae al de fábrica, que es lo que tiene la inmensa mayoría de los Macs.

---

## Compilar y probar

```bash
./build.sh          # build/MagicMouseGestures.app y build/mmg-probe
swift test          # reproduce las grabaciones reales contra el reconocedor
```

La firma *ad-hoc* no es cosmética: un binario sin firmar cambia de identidad en
cada compilación y macOS se olvida del permiso de Accesibilidad cada vez.

### Los tests son grabaciones, no maquetas

`Fixtures/` guarda frames capturados en el Magic Mouse del usuario, y `swift
test` los pasa por el reconocedor de verdad. Es la única forma que tiene este
proyecto de comprobar algo sin una mano encima del mouse, y por eso las
grabaciones están versionadas: sin el hardware delante no se pueden volver a
producir.

| Grabación | Qué debe pasar |
|---|---|
| `flick.jsonl` — flicks rápidos deliberados | 12 disparos, 8 hacia arriba |
| `ruido.jsonl` — uso normal con la mano encima | ninguno |
| `barrido-lento.jsonl` — barridos de 2–7 s | ninguno |
| `lateral.jsonl` — intentos de barrido horizontal | ninguno |

Para mirar una a mano, con otros umbrales:

```bash
./build/mmg-probe --replay Fixtures/flick.jsonl --threshold 0.20 --window 250
```

### Diagnóstico en vivo

```bash
./build/mmg-probe             # dispositivos y contactos, en crudo
./build/mmg-probe --live      # el reconocedor real, avisando cuándo dispararía
./build/mmg-probe --record x.jsonl   # graba para poder repetir esto luego
./build/mmg-probe --calibrate --apply # mide invertY/invertX/umbral y los escribe
./build/mmg-probe --hotkeys   # qué atajo dispararía cada acción
./build/mmg-probe --raw       # los 96 bytes crudos, si los offsets bailan
```

Ninguno inyecta eventos: son seguros de dejar corriendo.

### Instalar

```bash
cp -r build/MagicMouseGestures.app /Applications/
open /Applications/MagicMouseGestures.app
```

Pide **dos** permisos y necesita los dos:

- **Accesibilidad**, para publicar los atajos.
- **Monitorización de entrada**, para leer los dedos. Este es el que se olvida,
  porque no falla ruidosamente: la app arranca, el dispositivo aparece, y no
  llega ni un contacto.

Si ya se los habías dado a una compilación anterior, quítalos y vuelve a
añadirlos: la identidad del binario cambia al recompilar.

Para que arranque solo: Ajustes del Sistema → General → Ítems de inicio → `+`.

---

## Lo que se midió, y con qué números

Grabaciones reales, agosto de 2026. Magic Mouse USB-C (2024), `familyID` 112,
superficie 51,5 × 90,6 mm.

**El gesto de tres dedos funciona, pero solo como flick.** Velocidad de pico por
dedo en una ventana de 0,22 s:

| | recorrido |
|---|---|
| Flick rápido deliberado | 0,19 – 0,46 (mediana 0,34) |
| Uso normal del mouse | 0,06 – 0,17 |

Hueco limpio entre 0,17 y 0,19. Con el umbral en 0,24: 9 de 11 flicks disparan,
0 de 6 tramos de uso normal. Cero falsos positivos.

**El eje Y sube hacia adelante.** `invertY: false`, y adelante es Mission
Control, que es lo que se pidió.

**Izquierda y derecha no existen en este dispositivo.** No es cuestión de
ajustar el umbral: tres dedos ya ocupan de x=0,17 a x=0,88 de 51,5 mm, así que
no queda recorrido lateral. Un intento deliberado de barrido horizontal movió
0,024 — *menos* que los 0,056 de ruido lateral incidental del uso normal. No hay
umbral que separe eso, y por eso `left` y `right` vienen sin asignar.

**Tres dedos se detectan de forma estable**, con parpadeos del dedo exterior en
los bordes que absorbe `dropoutGraceMs`.

---

## Configuración

`~/.config/magic-mouse-gestures/config.json`, creado con valores por defecto en
el primer arranque. «Recargar configuración» desde el menú lo relee sin
reiniciar.

| Clave | Por defecto | Qué hace |
|---|---|---|
| `enabled` | `true` | Interruptor general |
| `fingers` | `3` | Dedos que exige el gesto |
| `swipeThreshold` | `0.24` | Recorrido mínimo **dentro de la ventana**, en unidades 0–1 |
| `swipeWindowMs` | `220` | La ventana. Más corta = más exigente con la velocidad |
| `axisDominance` | `1.6` | Cuánto debe ganar el eje dominante al otro |
| `dropoutGraceMs` | `200` | Cuánto puede desaparecer un dedo sin contar como levantado |
| `invertY` / `invertX` | `false` | Voltear el eje. Medido, no supuesto |
| `deviceSelection` | `"auto"` | `auto` (externo + sensor vertical), `external`, `all` |
| `useSystemShortcuts` | `true` | Leer tus atajos reales en vez de asumir los de fábrica |
| `suppressScroll` | `true` | Tragarse el scroll espurio |
| `suppressScrollTailMs` | `250` | Cuánto seguir tragándoselo tras el último frame |
| `freezeCursorDuringGesture` | `false` | Congelar también el cursor durante el gesto |
| `bindings` | ver abajo | Dirección → acción |
| `overrides` | `{}` | Forzar la combinación de teclas de una acción |

`swipeThreshold` y `swipeWindowMs` van juntos: son numerador y denominador de
una velocidad. Subir el umbral o acortar la ventana exigen un flick más seco.
Es el equivalente del deslizador de sensibilidad que exponen BTT y Multitouch, y
existe por la misma razón: en una superficie así de pequeña esto se afina por
mano.

```json
{
  "bindings": {
    "up": "missionControl",
    "down": "appExpose",
    "left": "none",
    "right": "none"
  },
  "overrides": {
    "missionControl": { "keyCode": 126, "modifiers": ["control"] }
  }
}
```

Acciones disponibles: `missionControl`, `appExpose`, `spaceLeft`, `spaceRight`,
`showDesktop`, `launchpad`, `none`.

---

## Lo que sigue sin saberse

Las grabaciones contestan qué hace el reconocedor. No contestan cómo se siente:

- **Si el flick sale natural o hay que ensayarlo.** El umbral 0,24 sale de un
  hueco limpio en los datos, pero el hueco se midió con el usuario intentando
  hacer flicks a propósito. Con la mano relajada puede quedar corto o pasarse.
- **Si el flick de vuelta dispara sin querer.** En `flick.jsonl` hay 8 disparos
  hacia arriba y 4 hacia abajo, y no se sabe cuáles de esos 4 eran deliberados.
  Si al usar la app aparece un App Exposé detrás de cada Mission Control, la
  respuesta es dejar `down` sin asignar, o pedir una pausa tras disparar.
- **Si la supresión de scroll llega a tiempo.** El *tap* ve el scroll que macOS
  genera al ver dos de los tres dedos; la carrera entre ese scroll y el primer
  frame multitouch no está medida.
- **`showDesktop` y `launchpad`** solo tienen respaldo de fábrica (fn+F11,
  fn+F4), sin búsqueda en el sistema.
- **Los IDs simbólicos 32 / 36.** 79 y 81 están confirmados (Ctrl+← / Ctrl+→).
  Si los otros fallan se cae al atajo de fábrica, que es correcto igual.

---

## Siguiente

Instalar la app, concederle los dos permisos y usar el mouse un rato con ella
puesta. Las tres preguntas que solo se contestan así:

1. ¿Sale Mission Control cuando quieres, sin ensayar el movimiento?
2. ¿Sale alguna vez cuando **no** quieres?
3. ¿El scroll normal sigue sintiéndose igual de bien?
