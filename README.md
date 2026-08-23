# Magic Mouse Gestures

Gestos de trackpad en el Apple Magic Mouse. Tres dedos hacia arriba abre Mission
Control, igual que en el trackpad.

macOS no tiene ningún gesto nativo de tres dedos para el Magic Mouse, aunque el
hardware sí reporta los contactos. Esto llena ese hueco: lee los dedos con el
framework privado de multitouch y dispara el mismo atajo del sistema que ya usa
el trackpad.

## Estado

Primera implementación. **Compila limpio** en CI (macOS, Xcode 26.6, Swift 6.3.3,
arm64), pero el comportamiento **no está verificado en hardware** todavía: se
escribió sin acceso a un Mac. El primer paso es el diagnóstico.

```bash
git clone https://github.com/j0KZ/Magic_Mouse.git
cd Magic_Mouse
git checkout claude/magic-mouse-trackpad-gestures-98dlq8
./build.sh
./build/mmg-probe          # no inyecta nada; seguro para experimentar
```

Requiere Xcode o las Command Line Tools instaladas.

Luego:

```bash
cp -r build/MagicMouseGestures.app /Applications/
open /Applications/MagicMouseGestures.app   # pedirá Accesibilidad
```

## Gestos por defecto

| Gesto | Acción |
|---|---|
| 3 dedos arriba | Mission Control |
| 3 dedos abajo | App Exposé |
| 3 dedos izquierda | Escritorio anterior |
| 3 dedos derecha | Escritorio siguiente |

Configurable en `~/.config/magic-mouse-gestures/config.json`.

## Cómo funciona

Deliberadamente aburrido: nada de eventos `DockSwipe` sintéticos ni campos de
`CGEvent` sin documentar. El gesto dispara la acción al instante en vez de
animarla bajo el dedo — a cambio, funciona igual en macOS 26 y en macOS 27, que
sí rompió la ruta de la animación fluida.

## Documentación

- [Investigación y factibilidad](docs/01-investigacion-y-factibilidad.md) — qué
  se puede hacer, qué no, y por qué esta ruta.
- [Arquitectura y uso](docs/02-arquitectura-y-uso.md) — cómo está construido,
  configuración completa y lo que falta verificar.

## Requisitos

- macOS 14 o posterior (probado como objetivo en 26 Tahoe y 27 Golden Gate)
- Apple Silicon o Intel
- Magic Mouse 1, 2 o USB-C
- Permiso de Accesibilidad

Usa un framework privado y necesita el sandbox apagado, así que no puede ir a la
Mac App Store.

## Licencia

MIT
