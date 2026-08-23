# Contexto del proyecto

Gestos de trackpad en el Apple Magic Mouse. El objetivo original: **tres dedos
hacia arriba en el mouse abre Mission Control**, igual que en el trackpad.

## Traspaso desde la sesión en la nube

Esto se escribió en un contenedor Linux sin acceso al Mac y sin toolchain de
Swift. Si estás leyendo esto desde una sesión local en el Mac, **eres tú quien
puede hacer lo que aquella no podía**.

### Estado real, sin adornos

| | |
|---|---|
| Investigación de factibilidad | Hecha — `docs/01-…` |
| Implementación de la ruta estable | Escrita — `Sources/` |
| ¿Compila? | **Sí.** CI en macOS, Xcode 26.6, Swift 6.3.3, arm64 |
| ¿Funciona? | **Desconocido.** Nada verificado en hardware |

Compilar limpio no dice nada sobre si los offsets de la struct son correctos, si
el eje Y va en la dirección asumida, o si el sensor ve tres dedos de forma
estable en 5,7 cm.

### Decisiones ya tomadas — no las reabras sin motivo

- **Ruta de atajo, no animación fluida.** El gesto dispara el mismo atajo del
  sistema que usa el trackpad (Ctrl+↑ y compañía) en vez de falsificar eventos
  `DockSwipe`. El usuario lo eligió explícitamente. A cambio funciona igual en
  macOS 26 y 27; la ruta fluida se rompió en el 27.
- **Todo por `dlopen`/`dlsym`.** En arm64e las llamadas directas al framework
  privado mueren por pointer authentication. No lo "simplifiques" a `extern`.
- **Offsets crudos en vez de una struct de Swift.** El layout de C no está
  garantizado por el compilador. `mmg-probe --raw` existe para re-verificarlos.

### Hardware del usuario

MacBook Pro 14" M5 Pro, 64 GB · Magic Mouse USB-C (2024) · macOS 26 Tahoe,
con macOS 27 Golden Gate saliendo a mediados de septiembre de 2026.

## Lo primero que hay que hacer

```bash
./build.sh
./build/mmg-probe
```

`mmg-probe` es de solo lectura: no inyecta ningún evento, es seguro dejarlo
corriendo. Las cinco preguntas que responde están en
`docs/02-arquitectura-y-uso.md`, sección «Fase 0». En resumen:

1. ¿Aparece el Magic Mouse, con qué `familyID` y qué dimensiones de superficie?
2. ¿Tres dedos se detectan de forma estable, o parpadea a dos?
3. Al deslizar hacia adelante, **¿el eje Y sube o baja?** → decide `invertY`
4. ¿Cuánto recorrido cómodo hay? → ajusta `swipeThreshold`, hoy en 0.09 a ojo
5. ¿Salen «valores fuera de rango»? → el layout cambió, hace falta `--raw`

Con eso se ajusta la configuración y se pasa a afinar la supresión del scroll,
que es lo que decide si el gesto se siente pulido o improvisado.

## Preguntas abiertas que el usuario no ha contestado

Se le preguntaron y las dejó pendientes. No asumas una respuesta:

- Si tres dedos resulta incómodo, ¿qué alternativa prefiere? (dos dedos +
  modificador, tip-tap, doble toque con dos dedos, o insistir con tres)
- ¿Congelar también el cursor durante el gesto, o solo matar el scroll?
- ¿Abrir un Pull Request, o basta la rama?

## Convenciones

- Rama de trabajo: `claude/magic-mouse-trackpad-gestures-98dlq8`
- Documentación y commits en español
- `swift build` antes de cada commit; el CI de `.github/workflows/build.yml`
  compila en un runner de macOS y debe seguir verde
