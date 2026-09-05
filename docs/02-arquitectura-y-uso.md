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

**`ActionEmitter`** — publica el atajo con los bits que pone un teclado de
verdad, y eso no es cosmético: un `CGEvent` con solo `.maskControl` llega al
sistema —un event tap lo ve, con el keycode correcto— y el WindowServer lo
descarta sin decir nada. Las flechas de un teclado Mac viajan siempre con `fn` y
`numericPad`, y el atajo quedó registrado con ellos. Ver la sección «Fallos que
no dan error».

Para cada acción tiene el atajo de fábrica de Apple como
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
| `flick.jsonl` — flicks rápidos deliberados | 14 disparos, 10 hacia arriba |
| `flick-natural.jsonl` — uso real, más suave | al menos 9 de 10 trazos |
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

**El gesto de tres dedos funciona, pero solo como flick.** Y el ajuste que salió
de las primeras grabaciones era malo, por una razón que conviene recordar: se
midió con flicks hechos *a propósito para medir*, que son mucho más secos que los
que hace la mano cuando intenta usar la app. Con 0,24 / 220 ms, de 10 flicks
naturales disparaba **uno**. Desde fuera eso es «no funciona».

Barriendo los dos parámetros contra una grabación de uso real apareció algo
contraintuitivo: **la ventana corta separa mejor que la larga.** Una mano apoyada
deriva a velocidad casi constante, así que su recorrido crece con la ventana; un
flick es una ráfaga y se satura en cuanto la ventana lo supera. Ensanchar la
ventana ayuda más a la deriva que al gesto.

| ventana | flick natural (mediana) | peor deriva | separación |
|---|---|---|---|
| 80 ms | 0,078 | 0,058 | **1,34×** |
| 120 ms | 0,104 | 0,089 | 1,17× |
| 220 ms | 0,168 | 0,160 | 1,05× |

Con 80 ms / 0,06: 9 de 10 flicks naturales, 14 de 14 deliberados, y cero falsos
positivos en uso normal, barrido lento y lateral.

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
| `swipeThreshold` | `0.06` | Recorrido mínimo **dentro de la ventana**, en unidades 0–1 |
| `swipeWindowMs` | `80` | La ventana. Más corta separa mejor, ver arriba |
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

## Fallos que no dan error

Los cuatro se manifiestan igual —el gesto no hace nada, o hace scroll— y ninguno
produce un error, un aviso ni una línea en el log. Están aquí porque cada uno
costó horas y ninguno se deduce leyendo el código.

**Un atajo sintético sin los bits del teclado se descarta en silencio.** Comparar
un Ctrl+↑ real con el fabricado, capturados con `mmg-probe --sniff`:

    real       keycode 126  flags 0x00A40101  control+fn+numericPad+nonCoalesced
    fabricado  keycode 126  flags 0x20040000  control

El evento fabricado *llega* — el tap lo ve. Simplemente no coincide con lo que
Mission Control tiene registrado. `mmg-probe --emit real` lo comprueba solo,
contando las ventanas del Dock antes y después.

**Ctrl+↑ es un interruptor, así que probar dos veces seguidas parece no hacer
nada.** La primera lo abre, la segunda lo cierra. Por eso el diagnóstico se mide
solo en vez de preguntar «¿lo viste?».

**Recompilar invalida los dos permisos.** La firma ad-hoc cambia de hash en cada
compilación y macOS descarta la concesión sin avisar; la fila sigue en la lista,
con su nombre, y activarla no hace nada porque ya no corresponde a ese binario.
Peor: se acumulan filas duplicadas y es imposible saber cuál es la buena. Lo que
funciona es limpiar y volver a conceder:

    tccutil reset ListenEvent dev.j0kz.magicmousegestures
    tccutil reset Accessibility dev.j0kz.magicmousegestures

**El permiso llega después del primer arranque, no antes.** Nadie concede
Accesibilidad antes de ejecutar una app por primera vez, así que el `CGEventTap`
del supresor falla en el arranque inicial siempre. Sin reintento, el gesto acaba
funcionando mientras el scroll que venía a sustituir sigue ocurriendo debajo. El
watchdog lo reintenta en cuanto el permiso aparece.

Y una regla que sale de todo esto: **la app escribe `estado.txt` en
`~/.config/magic-mouse-gestures/` en cada arranque y en cada gesto.** Permisos,
dispositivos, si el tap subió y cuál fue el último gesto. Es la diferencia entre
depurar esto y adivinarlo.

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

**Funciona.** Probado en el hardware el 2026-09-05: flick de tres dedos hacia
adelante abre Mission Control.

Lo que queda, por orden de lo que más molesta:

1. **Firmar con una identidad estable en vez de ad-hoc.** Hoy cada recompilación
   invalida los dos permisos y hay que volver a concederlos. Con un certificado
   autofirmado en el llavero, el requisito designado deja de depender del hash y
   la concesión sobrevive.
2. **Decidir qué hacer con el gesto de vuelta.** La mano que vuelve después de un
   flick dispara App Exposé de vez en cuando. Se quita dejando `down` sin
   asignar, o exigiendo una pausa después de disparar. Falta usarlo un rato para
   saber si molesta de verdad.
3. **Medir la carrera del supresor de scroll.** El tap se traga el scroll que
   macOS genera al ver dos de los tres dedos, pero nadie ha medido si llega antes
   que el primer evento.
