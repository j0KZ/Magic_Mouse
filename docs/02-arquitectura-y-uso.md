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

### Por qué cada pieza es como es

**`MultitouchBridge`** — todo pasa por `dlopen`/`dlsym`. En arm64e, declarar
estos símbolos como `extern` y llamarlos directo revienta con *bus error* por
*pointer authentication*. Tampoco usamos `MTDeviceGetDeviceID`, que tiene una
convención de llamada inestable.

**`TouchDecoder`** — en vez de replicar la struct de C en Swift, donde el
compilador no promete el mismo layout, leemos seis campos en offsets fijos de
cada bloque de 96 bytes. `mmg-probe --raw` vuelca esos bytes para poder
re-verificar los offsets contra cualquier build de macOS.

**`GestureRecognizer`** — reglas estrictas a propósito, porque la superficie es
pequeña y una mano apoyada genera mucho ruido: el número de dedos debe ser
exactamente el configurado al disparar, un eje debe dominar claramente al otro,
tiene que ocurrir dentro de una ventana de tiempo, y después de disparar no
vuelve a armarse hasta que levantas la mano.

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
./build.sh
```

Produce `build/MagicMouseGestures.app` y `build/mmg-probe`.

La firma *ad-hoc* no es cosmética: un binario sin firmar cambia de identidad en
cada compilación y macOS se olvida del permiso de Accesibilidad cada vez.

### Fase 0 — el diagnóstico, antes de instalar nada

```bash
./build/mmg-probe
```

No inyecta ningún evento, así que es seguro dejarlo corriendo mientras
experimentas. Lo que necesito que me digas:

1. **¿Aparece el Magic Mouse en la lista de dispositivos, y con qué `familyID` y
   qué dimensiones de superficie?** La heurística actual es «externo + sensor
   más alto que ancho». Si falla, con el `familyID` lo fijo sin adivinar.
2. **Apoya tres dedos. ¿Llega a decir «3 dedos»? ¿Se mantiene o parpadea a 2?**
   Esto decide si tres dedos es viable o hay que caer a dos dedos + modificador.
3. **Desliza los tres dedos hacia adelante. ¿El segundo número del centro sube o
   baja?** Si baja, hay que poner `invertY: true`. No lo sé de antemano y no
   quiero inventármelo.
4. **¿Cuánto cambia ese número entre los dos extremos del recorrido cómodo?**
   Con eso ajusto `swipeThreshold`, que ahora está en 0.09 a ojo.
5. **¿Sale «valores fuera de rango»?** Entonces el layout de la struct cambió en
   tu macOS y necesito la salida de `mmg-probe --raw`.

```bash
./build/mmg-probe --hotkeys   # qué atajo dispararía cada acción
./build/mmg-probe --devices   # solo la lista de dispositivos
```

### Instalar

```bash
cp -r build/MagicMouseGestures.app /Applications/
open /Applications/MagicMouseGestures.app
```

Pide Accesibilidad al arrancar. Ajustes del Sistema → Privacidad y seguridad →
Accesibilidad. Si ya se lo habías dado a una compilación anterior, quítalo y
vuelve a añadirlo.

Para que arranque solo: Ajustes del Sistema → General → Ítems de inicio → `+`.

---

## Configuración

`~/.config/magic-mouse-gestures/config.json`, creado con valores por defecto en
el primer arranque. «Recargar configuración» desde el menú lo relee sin reiniciar.

| Clave | Por defecto | Qué hace |
|---|---|---|
| `enabled` | `true` | Interruptor general |
| `fingers` | `3` | Dedos que exige el gesto |
| `swipeThreshold` | `0.09` | Distancia mínima, en unidades normalizadas 0–1 |
| `axisDominance` | `1.6` | Cuánto debe ganar el eje dominante al otro |
| `maxGestureDuration` | `1.2` | Segundos; más lento que esto es un reposo, no un gesto |
| `invertY` / `invertX` | `false` | Voltear el eje. **A confirmar con la fase 0** |
| `deviceSelection` | `"auto"` | `auto` (externo + sensor vertical), `external`, `all` |
| `useSystemShortcuts` | `true` | Leer tus atajos reales en vez de asumir los de fábrica |
| `suppressScroll` | `true` | Tragarse el scroll espurio |
| `suppressScrollTailMs` | `250` | Cuánto seguir tragándoselo tras levantar los dedos |
| `freezeCursorDuringGesture` | `false` | Congelar también el cursor durante el gesto |
| `bindings` | ver abajo | Dirección → acción |
| `overrides` | `{}` | Forzar la combinación de teclas de una acción |

```json
{
  "bindings": {
    "up": "missionControl",
    "down": "appExpose",
    "left": "spaceLeft",
    "right": "spaceRight"
  },
  "overrides": {
    "missionControl": { "keyCode": 126, "modifiers": ["control"] }
  }
}
```

Acciones disponibles: `missionControl`, `appExpose`, `spaceLeft`, `spaceRight`,
`showDesktop`, `launchpad`, `none`.

---

## Lo que sé que no sé

Esto se escribió sin acceso al Mac. Nada de esto está verificado en hardware, y
son exactamente los puntos que resuelve la fase 0:

- **No compilé el proyecto.** No hay toolchain de Swift donde se escribió. Es
  código escrito con cuidado, no código probado.
- **La dirección del eje Y** en el Magic Mouse. De ahí `invertY`.
- **Los offsets de la struct de contacto** (96 bytes) vienen de implementaciones
  públicas conocidas, pero hay que confirmarlos en macOS 26. Por eso `--raw`.
- **La heurística de selección de dispositivo.** Prefiero una heurística
  explicable a un `familyID` inventado.
- **Los IDs simbólicos 32 / 36 / 79 / 81.** Los dos últimos están confirmados
  (79 → Ctrl+←, 81 → Ctrl+→). Los otros son razonables pero no verificados; si
  fallan, se usa el atajo de fábrica, que es correcto igual.
- **Si tres dedos son ergonómicamente viables** en 5,7 cm de ancho. Si en la
  práctica molesta, el plan B ya está previsto: dos dedos más modificador.
- **`showDesktop` y `launchpad`** solo tienen respaldo de fábrica (fn+F11,
  fn+F4), sin búsqueda en el sistema.

---

## Siguiente

Cuando corras `mmg-probe` y me pases lo que sale, ajusto los umbrales y el eje,
y seguimos con la fase 2 (afinar la supresión de scroll, que es lo que decide si
esto se siente bien) y la 3 (resto del mapa).
