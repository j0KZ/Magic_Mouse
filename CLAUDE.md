# Contexto del proyecto

Gestos de trackpad en el Apple Magic Mouse. El objetivo original: **tres dedos
hacia arriba en el mouse abre Mission Control**, igual que en el trackpad.

## Estado real, sin adornos

| | |
|---|---|
| Investigación de factibilidad | Hecha — `docs/01-…` |
| Implementación de la ruta estable | Escrita — `Sources/` |
| ¿Compila? | Sí. CI en macOS, Xcode 26.6, Swift 6.3.3, arm64 |
| ¿El reconocedor acierta? | **Sí, medido.** `swift test` reproduce grabaciones reales |
| ¿Se siente bien en la mano? | **Desconocido.** Nadie ha usado la app instalada |

La distinción importa. Contra las grabaciones de `Fixtures/`, el reconocedor
dispara en los 12 flicks deliberados y en ninguno de los tramos de uso normal ni
de barrido lento. Lo que eso **no** dice: si el flick sale natural sin ensayarlo,
si el movimiento de volver dispara sin querer, y si la supresión de scroll llega
a tiempo. Eso solo se sabe instalando la app.

## Lo que ya se midió — no lo reabras sin datos nuevos

Todo esto sale de grabaciones del hardware del usuario, no de suposiciones. Los
números y su procedencia están en `docs/02-arquitectura-y-uso.md`, sección «Lo
que se midió», y las grabaciones en `Fixtures/`.

- **El gesto es un flick, no un barrido.** La compuerta es de velocidad
  (0,24 por ventana de 220 ms), no de distancia. Un barrido lento recorre lo
  mismo que un flick y es indistinguible de la mano apoyada; medido en velocidad
  hay un hueco limpio entre 0,17 (uso normal) y 0,19 (flick más flojo).
- **`invertY: false`.** Adelante sube y. Medido.
- **Izquierda y derecha no existen en este dispositivo.** Tres dedos ocupan de
  x=0,17 a x=0,88 de 51,5 mm. Un barrido lateral deliberado movió 0,024, menos
  que el ruido lateral del uso normal (0,056). Vienen sin asignar a propósito.

## Decisiones ya tomadas — no las reabras sin motivo

- **Ruta de atajo, no animación fluida.** El gesto dispara el mismo atajo del
  sistema que usa el trackpad (Ctrl+↑ y compañía) en vez de falsificar eventos
  `DockSwipe`. El usuario lo eligió explícitamente. A cambio funciona igual en
  macOS 26 y 27; la ruta fluida se rompió en el 27.
- **Todo por `dlopen`/`dlsym`.** En arm64e las llamadas directas al framework
  privado mueren por pointer authentication. No lo "simplifiques" a `extern`.
- **Offsets crudos en vez de una struct de Swift.** El layout de C no está
  garantizado por el compilador. `mmg-probe --raw` existe para re-verificarlos.
- **Las grabaciones de `Fixtures/` están versionadas.** Sin un Magic Mouse
  delante no se pueden volver a producir, y son lo único que convierte «el
  reconocedor parece razonable» en una medida. No las muevas a `build/`, que
  está en `.gitignore` — ahí es donde estuvieron a punto de perderse.

## Trampas de este hardware que ya costaron caro

Las tres se ven idénticas desde fuera («no pasa nada»), y ninguna da un error:

- **El stream multitouch no manda frame de cierre: simplemente para.** Nada
  puede depender de que llegue un aviso de «ya no hay dedos». La supresión de
  scroll es un plazo que cada frame empuja hacia adelante, nunca un flag que
  alguien tenga que bajar; y el trazo del reconocedor caduca solo.
- **`build.sh` copiando encima del binario anterior** invalida la firma ad-hoc
  en arm64 y macOS lo mata en silencio: exit 137, cero salida, ni con `--help`.
  Por eso hay `rm` antes de `cp`.
- **Monitorización de entrada** es el permiso que nadie recuerda. Sin él
  `MTDeviceStart` devuelve éxito, el dispositivo aparece en la lista, y no llega
  ni un contacto. Es un permiso distinto por binario: dárselo al Terminal para
  `mmg-probe` no se lo da a la app.

## Hardware del usuario

MacBook Pro 14" M5 Pro, 64 GB · Magic Mouse USB-C (2024) · macOS 26 Tahoe,
con macOS 27 Golden Gate saliendo a mediados de septiembre de 2026.

## Lo primero que hay que hacer

```bash
swift test        # el reconocedor contra las grabaciones reales
./build.sh
```

Y después, lo único que queda por responder, que necesita la app instalada y sus
dos permisos: ¿sale Mission Control cuando quieres, no sale cuando no quieres, y
el scroll normal sigue sintiéndose igual?

## Preguntas abiertas que el usuario no ha contestado

Se le preguntaron y las dejó pendientes. No asumas una respuesta:

- Si tres dedos resulta incómodo, ¿qué alternativa prefiere? (dos dedos +
  modificador, tip-tap, doble toque con dos dedos, o insistir con tres)
- ¿Congelar también el cursor durante el gesto, o solo matar el scroll?
- ¿Abrir un Pull Request, o basta la rama?

## Convenciones

- Rama de trabajo: `claude/magic-mouse-trackpad-gestures-98dlq8`
- Documentación y commits en español
- `swift test` y `swift build` antes de cada commit; el CI de
  `.github/workflows/build.yml` compila y pasa los tests en un runner de macOS y
  debe seguir verde
