# Magic Mouse → gestos de trackpad: investigación y factibilidad

**Fecha:** 23 de agosto de 2026
**Objetivo del usuario:** tener en el Magic Mouse los gestos del trackpad, en particular
*tres dedos hacia arriba* (Mission Control), y poder simular el resto de gestos.
**Estado:** investigación previa a escribir código. Sin acceso al Mac todavía.

---

## 1. Veredicto corto

**Sí es factible, y no hay que inventar nada desde cero: la técnica está probada y hay
código abierto reciente que ya la usa en macOS 26 y en la beta de macOS 27.**

El trabajo se divide en dos mitades independientes:

| Mitad | Qué hace | Dificultad | Riesgo |
|---|---|---|---|
| **Entrada** — leer los dedos sobre el Magic Mouse | `MultitouchSupport.framework` (API privada) entrega los contactos crudos: posición, presión, elipse, estado | Baja–media | Bajo. API estable desde ~2009 |
| **Salida** — que macOS reaccione como si fuera el trackpad | Inyectar eventos de gesto sintéticos (`DockSwipe`, magnify, rotate) vía `CGEventPost` | **Alta** | **Alto.** Formato no documentado y **cambió en macOS 27** |

El punto crítico no es detectar los tres dedos —eso es fácil—. El punto crítico es
**hacer que Mission Control se abra siguiendo el dedo** (animación fluida, reversible a
medio camino), porque eso obliga a falsificar eventos HID internos de Apple.

Si aceptamos una versión "sin animación fluida" (el gesto dispara Mission Control de
golpe, como el atajo Ctrl+↑), la dificultad baja de **alta** a **trivial** y el riesgo
de que macOS 27 lo rompa desaparece casi por completo.

---

## 2. Tu contexto: hardware y sistema

### macOS

- Hoy corres **macOS 26 "Tahoe"** (la última pública es la 26.6).
- **macOS 27 "Golden Gate"** se presentó en la WWDC del 8 de junio de 2026, va por la
  cuarta beta pública (17 de agosto) y sale al público **alrededor del 14 de septiembre
  de 2026**, es decir, en tres semanas.
- macOS 27 **elimina el soporte para Macs Intel** y es la última versión con Rosetta 2
  completo. Si tu Mac es Apple Silicon, sin problema; si es Intel, te quedas en 26 y
  paradójicamente eso te da un blanco *más estable* para esto.

### El Magic Mouse

- El modelo vigente es el **Magic Mouse (USB-C) de 2024**. Da igual cuál tengas: el 1
  (2009), el 2 (2015) y el USB-C reportan multitouch por el mismo camino.
- **Rumor relevante:** Apple prepara un Magic Mouse rediseñado para **finales de 2026**,
  con controles táctiles y de voz, junto con los MacBook Pro OLED / M6. Es decir, existe
  la posibilidad real de que Apple resuelva parte de esto por hardware en unos meses.
  No lo consideraría razón para no hacerlo, pero sí para no sobreinvertir.
- El hardware **sí distingue muchos dedos**: el driver de Linux para `hid-magicmouse`
  reserva arreglos de **16 contactos** con IDs de seguimiento individuales. No hay
  límite físico de "solo dos dedos".

### Qué hace macOS de fábrica con el Magic Mouse

Ajustes del Sistema → Ratón solo ofrece gestos de **uno y dos dedos**:

- 1 dedo: deslizar entre páginas, doble toque = zoom inteligente
- 2 dedos: deslizar entre escritorios/apps a pantalla completa, doble toque = Mission Control

**No existe ningún gesto nativo de tres dedos en el Magic Mouse.** El sistema
literalmente no tiene un reconocedor para eso en este dispositivo, aunque el hardware
mande los tres contactos. Ahí está el hueco que vamos a llenar.

---

## 3. Cómo funciona por dentro

### 3.1 Entrada: leer los dedos

`/System/Library/PrivateFrameworks/MultitouchSupport.framework` — API privada pero
usada por medio mundo (BetterTouchTool, Jitouch, Mac Mouse Fix, MiddleClick…).

```
MTDeviceCreateList()                  → lista de dispositivos multitouch
MTDeviceIsBuiltIn(dev)                → distinguir trackpad interno del Magic Mouse
MTRegisterContactFrameCallback(dev, cb)
MTDeviceStart(dev, 0)
```

El callback entrega por cada frame un arreglo de contactos con:

```
id, posición normalizada (x,y ∈ 0..1), velocidad, presión,
eje mayor/menor de la elipse, ángulo del dedo, densidad, estado
(notTouching / starting / hovering / making / touching / breaking / lingering / leaving)
```

Con eso, detectar "tres dedos subiendo" es aritmética simple: tres contactos en estado
`touching` cuyo Δy promedio supera un umbral en una ventana de tiempo.

**Trampas conocidas de esta parte:**

- En **Apple Silicon con arm64e**, llamar directo a estas funciones revienta por
  *pointer authentication* (PAC): hay que cargarlas con `dlopen`/`dlsym`. También el ID
  del dispositivo conviene leerlo del offset 64 de la struct opaca en vez de llamar a
  `MTDeviceGetDeviceID`, que tiene convención de llamada inestable.
- La struct de contacto son ~96 bytes por dedo y su layout está determinado
  empíricamente. Hay que validar contra el macOS concreto.
- **El App Sandbox debe estar apagado.** Consecuencia directa: **esto nunca podrá ir a
  la Mac App Store.**

**Referencias en código que ya funcionan:**
`Kyome22/OpenMultitouchSupport` (paquete Swift mantenido, macOS 15+, Xcode 26),
`mhuusko5/M5MultitouchSupport`, `meatpaste/mousetoucher` (tap-to-click específico para
Magic Mouse; documenta el problema de PAC).

### 3.2 Salida: que el sistema crea que fue el trackpad

Aquí está el trabajo real. macOS no tiene API pública para "haz Mission Control con
animación de gesto". Lo que sí se puede es construir un `CGEvent` a mano y rellenarle
campos no documentados.

Los gestos de Dock (Mission Control, App Exposé, cambiar de escritorio, Launchpad,
mostrar Escritorio) viajan como **DockSwipe**, con tres variantes:

```
1 = horizontal  → cambiar de escritorio / página
2 = vertical    → Mission Control (↑) y App Exposé (↓)
3 = pinch       → Launchpad y Mostrar Escritorio
```

Y cada gesto es una secuencia de fases: `began → changed × N → ended`, con un
*origin offset* acumulado y una velocidad de salida. Eso es lo que da la animación que
sigue al dedo y que puedes cancelar a medio camino.

**Antes de macOS 27** se construye con `CGEventSetDoubleValueField` sobre campos
numéricos: 55 (tipo), 110 (subtipo IOHID), 132/134 (fase), 124/135 (offset — el 135 es
un `float32` reinterpretado como entero de 64 bits, sí, así de raro), 123/165 (tipo de
swipe), 129/130 (velocidad de salida), 119/139 (constantes mágicas por tipo).

**En macOS 27 esto cambió.** Los eventos DockSwipe sintéticos "a la vieja" son
ignorados. Hay dos soluciones ya publicadas y ambas funcionan:

1. **`CGEventSetHIDEvent`** — construir un `HIDEvent` real
   (`kIOHIDEventTypeDockSwipe`, campos motion/flavor/progress, con un evento hijo de
   velocidad al soltar) y envolverlo en un `CGEvent` de tipo 30. Es la vía que usa
   Mac Mouse Fix en su rama actual, con un `if @available(macOS 27.0, *)` que separa
   ambos caminos.
2. **Campo 4205** — adjuntar al `CGEvent` un *payload* IOHID serializado (cabecera de
   cola + registro *fluid touch gesture* + registro de velocidad, con tamaños exactos de
   28/40/28 bytes). Es la vía de `joshuarli/iss`.

Es decir: **el camino de macOS 27 ya está resuelto por terceros y podemos seguirlo.**
Pero confirma la naturaleza del riesgo: Apple rompe esto entre versiones mayores, sin
avisar, y hay que mantenerlo cada septiembre.

### 3.3 El plan B que casi nadie menciona, y que es muy sólido

Para muchos gestos no hace falta nada de lo anterior. Mission Control, App Exposé,
Launchpad, Mostrar Escritorio y cambiar de escritorio **tienen atajos de teclado
nativos** (`CGSSetSymbolicHotKey` / simular Ctrl+↑, Ctrl+↓, Ctrl+←/→). Cuando el
DockSwipe se rompió en la beta 1 de macOS 27, la solución provisional de Mac Mouse Fix
fue exactamente esa: detectar la versión del SO y disparar el atajo simbólico.

- **Pierdes:** la animación que sigue el dedo y la posibilidad de arrepentirte a medio
  gesto.
- **Ganas:** que funcione siempre, en cualquier versión de macOS, sin ingeniería inversa.

Mi recomendación es implementar **los dos** detrás de la misma interfaz y que el usuario
elija "fluido (experimental)" vs "instantáneo (estable)".

---

## 4. Matriz de factibilidad, gesto por gesto

| Gesto deseado en el Magic Mouse | ¿Se puede? | Cómo | Riesgo macOS 27 |
|---|---|---|---|
| **3 dedos arriba → Mission Control** | ✅ | DockSwipe vertical, o atajo simbólico | Medio / Nulo |
| 3 dedos abajo → App Exposé | ✅ | Igual | Medio / Nulo |
| 3 dedos ←/→ → cambiar de escritorio | ✅ | DockSwipe horizontal, o Ctrl+←/→ | Medio / Nulo |
| 4 dedos ←/→ | ⚠️ | Se detecta, pero en 5,7 cm de ancho es incómodo de verdad | — |
| Pellizcar para Launchpad / Mostrar Escritorio | ✅ | DockSwipe tipo pinch | Medio |
| Pellizcar para zoom (en apps) | ✅ | Evento magnify sintético (campo 110 = 8) | Bajo |
| Rotar con dos dedos | ✅ | Evento rotation sintético (campo 110 = 5) | Bajo |
| Doble toque con 2 dedos = zoom inteligente | ✅ | Ya es nativo, o `kIOHIDEventTypeZoomToggle` | Bajo |
| Deslizar entre páginas | ✅ | Ya es nativo, o navigation swipe sintético | Bajo |
| Toque para clic (tap-to-click) | ✅ | Trivial: contacto corto + `CGEventPost` de clic | Nulo |
| Clic derecho por zona / tip-tap | ✅ | Por posición x del contacto | Nulo |
| Botón central / arrastre de 3 dedos | ✅ | Detectable | Bajo |
| **Force Touch / clic fuerte** | ❌ | El Magic Mouse **no tiene Taptic Engine ni sensor de fuerza**. Se puede aproximar con el área de contacto (presión capacitiva), pero no es lo mismo y no hay respuesta háptica | — |
| **Que macOS lo trate como trackpad de verdad** | ❌ | Requeriría un dispositivo HID multitouch virtual; el stack `AppleMultitouchDevice` no está abierto a terceros. No hay implementación conocida que funcione | — |

---

## 5. Los tres problemas de verdad (que no salen en los tutoriales)

### 5.1 Interferencia con los gestos nativos ⚠️ este es el gordo

Cuando pones tres dedos sobre el Magic Mouse, **macOS no se queda quieto**: su propio
reconocedor ve dos de esos dedos y dispara *scroll*, y el movimiento de la mano mueve el
cursor. Está documentado como queja recurrente en el foro de BetterTouchTool
("three finger swipes trigger scrolling").

No hay forma limpia de decirle al sistema "ignora este dispositivo un momento". La
mitigación estándar es un **`CGEventTap` de sesión que se trague los eventos de scroll
(y opcionalmente los de movimiento) mientras haya tres contactos activos**, más apagar
en Ajustes del Sistema los gestos nativos que estorben. Funciona, pero es la parte que
determina si se siente pulido o chapucero, y hay que presupuestarla como trabajo real,
no como detalle.

### 5.2 Ergonomía

La superficie del Magic Mouse mide unos 5,7 cm de ancho por 11,3 cm de largo, y es
curva. Tres dedos caben, pero obligan a levantar la palma, y el recorrido hacia arriba
es corto. Esto es una limitación **física**, ninguna app la arregla.

Por eso vale la pena diseñar el mapeo con alternativas desde el principio:
2 dedos + tecla modificadora, tip-tap (dos dedos apoyados, uno toca), doble toque con
dos dedos, o umbrales de distancia más cortos que en el trackpad.

### 5.3 Permisos, firma y distribución

- **Accesibilidad**: obligatoria, para inyectar eventos.
- **Monitorización de entrada**: probable, según cómo se lea el multitouch.
- **Sandbox apagado** → **fuera de la Mac App Store**, sin excepciones.
- Para uso personal basta firma *ad-hoc*; para repartirla a otros hace falta cuenta de
  desarrollador y notarización, o el usuario pelea con Gatekeeper.
- Nada de esto requiere desactivar SIP ni inyectar código en procesos ajenos — bien.

---

## 6. Qué haría yo: tres caminos

### Opción A — No escribir nada: BetterTouchTool

Ya soporta Magic Mouse 1, 2 y 3 con gestos de 3 dedos (deslizar arriba/abajo/lados,
toque de 3 dedos, clic de 3 dedos, tip-taps) y 600+ acciones, con configuración por app.
Es de pago (~10 USD) y es lo que resuelve tu necesidad **hoy, esta tarde**.

**Cuándo elegirla:** si lo que quieres es el gesto funcionando y no el proyecto.
Alternativas: Jitouch (gratis), Mac Mouse Fix (código abierto, más centrado en ratones
normales), Multitouch.

Honestamente: si el objetivo es solo "tres dedos arriba en el mouse", esto es la
respuesta correcta y deberíamos decirlo antes de escribir mil líneas de Objective-C.

### Opción B — App propia mínima y honesta ← mi recomendación si quieres el proyecto

Un binario pequeño en Swift, sin interfaz o con un icono en la barra de menú, que haga
**solo** lo que tú pediste y lo haga bien:

```
MagicMouse
├── Multitouch/        lectura cruda vía dlopen (basado en OpenMultitouchSupport)
├── Recognizer/        máquina de estados: N dedos + dirección + umbrales
├── Emitter/
│   ├── DockSwipeEmitter      ruta fluida  (pre-27 por campos, 27+ por HIDEvent)
│   └── HotKeyEmitter         ruta estable (atajos simbólicos)
├── Suppressor/        CGEventTap que mata el scroll espurio durante el gesto
└── Config/            mapeo gesto → acción en un JSON
```

Ventajas: es tuyo, es auditable, arranca en un fin de semana la versión "estable", y la
ruta fluida se puede añadir después sin rehacer nada.

### Opción C — Emular un trackpad de verdad

Descartada. Sería lo ideal (macOS haría todos los gestos nativamente, sin falsificar
nada y sin romperse cada septiembre), pero exigiría un dispositivo multitouch virtual
por DriverKit y ese stack no está abierto a terceros. No conozco ninguna implementación
funcional. La menciono para cerrar la puerta explícitamente.

---

## 7. Plan por fases, si vamos por la B

| Fase | Entregable | Verificable en |
|---|---|---|
| **0** | Sonda de diagnóstico: imprime contactos crudos del Magic Mouse. Confirma layout de struct, PAC, nº máximo de dedos usable en tu mouse concreto | 1 sesión con el Mac |
| **1** | 3 dedos arriba → Mission Control por atajo simbólico. **Funciona seguro en 26 y en 27** | Fin de semana |
| **2** | Supresor de scroll espurio. Aquí se decide si se siente bien | Iteración con el Mac |
| **3** | Resto del mapa: abajo = App Exposé, ←/→ = escritorios, mapeo configurable | — |
| **4** | Ruta fluida con DockSwipe (animación que sigue el dedo), detrás de un flag experimental, con doble implementación 26 / 27 | — |
| **5** | Barra de menú, arranque al iniciar sesión, firma | — |

Nota de calendario: macOS 27 sale en ~3 semanas. Cualquier cosa que hagamos hay que
probarla en ambos, y la fase 4 es la que se romperá.

---

## 8. Lo que necesito de ti para seguir

1. **¿Qué Mac?** Apple Silicon o Intel (decide si macOS 27 te llega siquiera).
2. **Versión exacta de macOS** (`sw_vers`), y si piensas actualizar a 27 en septiembre.
3. **Qué Magic Mouse**: 1 (2009), 2 (Lightning) o USB-C (2024).
4. **La pregunta importante:** ¿quieres el gesto funcionando ya, o quieres construir la
   app? Si es lo primero, BetterTouchTool y cerramos. Si es lo segundo, empiezo por la
   fase 0.
5. **¿La animación fluida es requisito?** Si te basta con que Mission Control se abra al
   subir tres dedos, sin que la animación siga tu dedo, el proyecto es
   desproporcionadamente más simple y robusto.

---

## 9. Fuentes

- [BetterTouchTool — gestos de trackpad y Magic Mouse](https://folivora.ai/features/trackpad-gestures/) · [documentación de triggers](https://docs.folivora.ai/docs/trackpad-mouse/magic-mouse-trackpad/) · [hilo: los deslizamientos de 3 dedos disparan scroll](https://community.folivora.ai/t/three-finger-swipes-trigger-scrolling/28617)
- [Apple — Usar gestos Multi-Touch en el Mac](https://support.apple.com/es-es/102482)
- [joshuarli/iss — cambio instantáneo de espacios en macOS 26 y 27](https://github.com/joshuarli/iss)
- [noah-nuebling/mac-mouse-fix](https://github.com/noah-nuebling/mac-mouse-fix) · [issue #1876 — DockSwipe ignorado en macOS 27 beta](https://github.com/noah-nuebling/mac-mouse-fix/issues/1876)
- [Kyome22/OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport) · [mhuusko5/M5MultitouchSupport](https://github.com/mhuusko5/M5MultitouchSupport) · [meatpaste/mousetoucher](https://github.com/meatpaste/mousetoucher)
- [Driver HID de Linux para Magic Mouse (16 contactos)](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-magicmouse.c)
- [Macworld — macOS 27 Golden Gate](https://www.macworld.com/article/3139330/macos-27-mac-features-siri-apple-intelligence-release-date-compatibility.html) · [MacRumors — cuartas betas públicas, 17/08/2026](https://www.macrumors.com/2026/08/17/apple-ios-27-public-beta-4/)
- [MacRumors — Magic Mouse rediseñado en 2026](https://www.macrumors.com/2024/12/30/redesigned-magic-mouse-coming-in-2026/)
