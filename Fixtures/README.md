# Grabaciones reales del hardware

Frames capturados con `mmg-probe --record` sobre el Magic Mouse USB-C (2024,
`familyID` 112, superficie 51,5 × 90,6 mm) del usuario, en agosto de 2026. Un
frame por línea, JSON Lines; el formato lo define `FrameLog.Frame`.

Están en el repositorio a propósito. Sin un Magic Mouse delante no hay forma de
volver a producirlas, y son lo único que convierte «el reconocedor parece
razonable» en «el reconocedor dispara en estos 12 sitios y en ningún otro».
`Tests/` las reproduce en cada compilación.

| Archivo | Qué es | Qué debe pasar |
|---|---|---|
| `flick.jsonl` | Flicks rápidos y deliberados de 3 dedos | Dispara |
| `ruido.jsonl` | Uso normal del mouse, la mano encima | **No** dispara |
| `barrido-lento.jsonl` | Barridos de 3 dedos lentos (2–7 s) | **No** dispara |
| `lateral.jsonl` | Intentos de barrido horizontal de 3 dedos | **No** dispara — no se puede |

`barrido-lento.jsonl` es el contraejemplo que tumbó la primera versión del
reconocedor: con un umbral de distancia pura era indistinguible de la mano
apoyada. Es la razón de que la compuerta sea de velocidad.

`lateral.jsonl` documenta un límite físico, no un fallo de ajuste. Los tres
dedos ocupan de x=0,17 a x=0,88 de una superficie de 51,5 mm: no queda sitio
para moverse de lado. El desplazamiento lateral máximo medido en un intento
deliberado es 0,024, **menos** que el 0,056 de ruido lateral incidental durante
el uso normal. No hay umbral que los separe.

Para reproducir una a mano:

    ./build/mmg-probe --replay Fixtures/flick.jsonl
