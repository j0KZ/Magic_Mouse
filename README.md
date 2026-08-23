# Magic Mouse

Traer los gestos del trackpad al Apple Magic Mouse en macOS — empezando por
*tres dedos hacia arriba → Mission Control*.

## Estado

Fase de investigación. Todavía no hay código: primero hay que decidir el alcance.

📄 **[Investigación y factibilidad](docs/01-investigacion-y-factibilidad.md)** —
qué se puede hacer, cómo, qué se rompe en macOS 27 y qué alternativas existen.

## Resumen de una línea

Es factible: la entrada se lee con `MultitouchSupport.framework` y la salida se inyecta
como eventos de gesto sintéticos. Lo difícil no es detectar los tres dedos, sino que la
animación siga al dedo — y ese formato de evento cambió en macOS 27.
