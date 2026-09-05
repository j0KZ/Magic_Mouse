<div align="center">

# Magic Mouse Gestures

**Three-finger flick on the Apple Magic Mouse opens Mission Control** — the same
gesture the trackpad has, on the mouse that never got it.

[English](#english) · [Español](#español) · MIT

</div>

---

## English

macOS gives the trackpad a three-finger swipe for Mission Control and gives the
Magic Mouse nothing, even though the mouse has a full multitouch surface under
the shell. This is a small menu bar app that reads that surface and fires the
same system shortcut the trackpad would have.

### It is a flick, not a swipe

This matters more than any setting. A hand resting on a Magic Mouse has three
fingers down more than half the time, and those fingers drift far and coherently
as the hand shifts. Distance alone cannot tell a deliberate gesture from that —
a slow three-finger slide and a hand settling look identical.

What separates them is **speed**. The recognizer measures travel inside a short
sliding window (80 ms), so a slow drift never accumulates enough to fire, no
matter how far it eventually travels.

And a detail that goes against intuition, arrived at by sweeping both knobs
against real recordings: **a shorter window separates better than a longer one.**
A resting hand drifts at a roughly steady speed, so its displacement keeps
growing with the window; a flick is a burst that saturates once the window
outlasts it. Widening the window helps the drift more than the gesture.

| Window | Natural flick (median) | Worst drift | Separation |
|---|---|---|---|
| 80 ms | 0.078 | 0.058 | **1.34×** |
| 120 ms | 0.104 | 0.089 | 1.17× |
| 220 ms | 0.168 | 0.160 | 1.05× |

### Install

```bash
./scripts/crear-identidad-de-firma.sh   # once: a stable signing identity
./build.sh
cp -r build/MagicMouseGestures.app /Applications/
open /Applications/MagicMouseGestures.app
```

It needs **two** permissions and will not work without both:

- **Accessibility** — to fire the shortcuts, and to swallow the stray scroll.
- **Input Monitoring** — to read your fingers. This is the one everyone forgets,
  because nothing fails loudly without it: the app starts, the device is listed,
  and not a single contact arrives.

The signing identity is not a nicety. With an ad-hoc signature the binary's
designated requirement is its own hash, so every rebuild is a new identity and
macOS quietly drops both grants — the row stays in System Settings, with its
name, and ticking it does nothing because it no longer matches that binary.

### Use

Everything lives in the menu bar icon: on/off, five sensitivity presets, what
each direction does, scroll suppression, language, and diagnostics.

Left and right are deliberately unbound. It is not a tuning problem: three
fingers already span x = 0.17 to 0.88 of a 51.5 mm surface, so there is nowhere
sideways to go. A deliberate sideways flick moved 0.024 — **less** than the 0.056
of incidental sideways noise during ordinary use. No threshold separates those.

### When it doesn't work

```bash
cat ~/.config/magic-mouse-gestures/estado.txt
```

The app writes that on every launch and every gesture: both permissions, how many
devices are attached, whether the scroll tap came up, and the last gesture it
recognized. Nearly every debugging session on this project would have been
shorter for reading it first.

Then, to tell a gesture that wasn't recognized from a shortcut that had no
effect — two different failures with identical symptoms:

```bash
./build/mmg-probe --live         # is the gesture recognized? (never injects)
./build/mmg-probe --emit real    # does the shortcut land? (verifies itself)
./build/mmg-probe --sniff        # what bits does a real key carry?
```

### How it is built

```
Magic Mouse
   │  raw contacts
   ▼
MultitouchBridge ──── dlopen/dlsym over MultitouchSupport.framework
   │                  (never direct calls: arm64e kills those with PAC)
   ▼
TouchDecoder ──────── six fields at fixed offsets in each 96-byte contact
   │
   ▼
GestureRecognizer ─── velocity gate, per-finger median, one shot per contact
   │
   ├──▶ ScrollSuppressor ── eats the scroll macOS generates on its own
   ▼
ActionEmitter ─────── posts the system's real shortcut (ctrl+↑ and friends)
```

`Fixtures/` holds real recordings from the hardware, and `swift test` replays
them through the recognizer on every build. They are committed on purpose: with
no Magic Mouse in front of you they cannot be reproduced, and they are the only
thing that turns "the recognizer looks reasonable" into a measurement.

Full architecture notes, and the four failures that produce no error at all, are
in [`docs/02-arquitectura-y-uso.md`](docs/02-arquitectura-y-uso.md) (Spanish).

### Requirements

macOS 14+, Apple Silicon or Intel, a Magic Mouse. Tested on macOS 26 Tahoe with
a Magic Mouse USB-C (2024) on a MacBook Pro M5 Pro.

---

## Español

macOS le da al trackpad el barrido de tres dedos para Mission Control y al Magic
Mouse no le da nada, aunque el mouse tenga una superficie multitáctil completa
bajo la carcasa. Esto es una app de barra de menús que lee esa superficie y
dispara el mismo atajo del sistema que dispararía el trackpad.

### Es un flick, no un barrido

Esto importa más que cualquier ajuste. Una mano apoyada en un Magic Mouse tiene
tres dedos abajo más de la mitad del tiempo, y esos dedos derivan lejos y de
forma coherente según la mano se acomoda. La distancia sola no distingue un gesto
deliberado de eso: un deslizamiento lento de tres dedos y una mano acomodándose
son idénticos.

Lo que los separa es la **velocidad**. El reconocedor mide el recorrido dentro de
una ventana corta (80 ms), así que una deriva lenta nunca acumula lo suficiente,
por lejos que llegue al final.

Y un detalle que va contra la intuición, sacado de barrer los dos parámetros
contra grabaciones reales: **la ventana corta separa mejor que la larga.** Una
mano apoyada deriva a velocidad casi constante, así que su recorrido crece con la
ventana; un flick es una ráfaga y se satura en cuanto la ventana lo supera.
Ensanchar la ventana ayuda más a la deriva que al gesto.

| Ventana | Flick natural (mediana) | Peor deriva | Separación |
|---|---|---|---|
| 80 ms | 0,078 | 0,058 | **1,34×** |
| 120 ms | 0,104 | 0,089 | 1,17× |
| 220 ms | 0,168 | 0,160 | 1,05× |

### Instalación

```bash
./scripts/crear-identidad-de-firma.sh   # una vez: identidad de firma estable
./build.sh
cp -r build/MagicMouseGestures.app /Applications/
open /Applications/MagicMouseGestures.app
```

Necesita **dos** permisos y no funciona sin los dos:

- **Accesibilidad** — para disparar los atajos y tragarse el scroll espurio.
- **Monitorización de entrada** — para leer los dedos. Éste es el que se olvida,
  porque no falla ruidosamente: la app arranca, el dispositivo aparece en la
  lista, y no llega ni un contacto.

La identidad de firma no es un adorno. Con firma ad-hoc el requisito designado
del binario es su propio hash, así que cada compilación es una identidad nueva y
macOS invalida los dos permisos sin decir nada: la fila sigue en Ajustes, con su
nombre, y activarla no hace nada porque ya no corresponde a ese binario.

### Uso

Todo está en el icono de la barra de menús: encendido, cinco niveles de
sensibilidad, qué hace cada dirección, supresión de scroll, idioma y diagnóstico.

Izquierda y derecha vienen sin asignar a propósito. No es un problema de ajuste:
tres dedos ya ocupan de x=0,17 a x=0,88 de una superficie de 51,5 mm, así que no
queda recorrido lateral. Un barrido lateral deliberado movió 0,024 — **menos**
que los 0,056 de ruido lateral incidental durante el uso normal. No hay umbral
que separe eso.

### Cuando no funciona

```bash
cat ~/.config/magic-mouse-gestures/estado.txt
```

La app lo escribe en cada arranque y en cada gesto: los dos permisos, cuántos
dispositivos hay enganchados, si el tap de scroll subió y cuál fue el último
gesto reconocido. Casi todas las sesiones de depuración de este proyecto se
habrían acortado leyéndolo primero.

Después, para distinguir «el gesto no se reconoció» de «el atajo no hizo efecto»,
que son dos fallos distintos con síntomas idénticos:

```bash
./build/mmg-probe --live         # ¿se reconoce el gesto? (no inyecta nada)
./build/mmg-probe --emit real    # ¿el atajo hace efecto? (se verifica solo)
./build/mmg-probe --sniff        # ¿qué bits lleva una tecla de verdad?
```

### Cómo está construido

El diagrama y las razones de cada pieza están en
[`docs/02-arquitectura-y-uso.md`](docs/02-arquitectura-y-uso.md), junto con los
cuatro fallos que no producen ningún error, la investigación de factibilidad y
los números medidos.

`Fixtures/` guarda grabaciones reales del hardware, y `swift test` las reproduce
por el reconocedor en cada compilación. Están versionadas a propósito: sin un
Magic Mouse delante no se pueden volver a producir, y son lo único que convierte
«el reconocedor parece razonable» en una medida.

### Requisitos

macOS 14+, Apple Silicon o Intel, un Magic Mouse. Probado en macOS 26 Tahoe con
un Magic Mouse USB-C (2024) en un MacBook Pro M5 Pro.

---

<div align="center">
<sub>MIT · <a href="docs/01-investigacion-y-factibilidad.md">Investigación de factibilidad</a> · <a href="docs/02-arquitectura-y-uso.md">Arquitectura y uso</a></sub>
</div>
