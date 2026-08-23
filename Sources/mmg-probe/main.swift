import Foundation
import CoreGraphics
import MagicMouseKit

// A read-only diagnostic. It never posts an event, so it is safe to leave
// running while you experiment with the mouse.

let args = Set(CommandLine.arguments.dropFirst())
let wantsRaw = args.contains("--raw")
let devicesOnly = args.contains("--devices")
let hotkeysOnly = args.contains("--hotkeys")

if args.contains("--help") || args.contains("-h") {
    print("""
    mmg-probe — diagnóstico de MagicMouseGestures

      (sin argumentos)  lista dispositivos y muestra los contactos en vivo
      --devices         lista los dispositivos multitouch y sale
      --hotkeys         muestra qué atajo se dispararía para cada acción y sale
      --raw             además, vuelca los 96 bytes crudos del primer contacto
      --help            esto

    No inyecta ningún evento. Ctrl-C para salir.
    """)
    exit(0)
}

// MARK: - Framework

guard MultitouchBridge.isAvailable else {
    print("✗ No se pudo cargar MultitouchSupport.framework")
    print("  \(MultitouchBridge.loadError ?? "sin detalle")")
    print("  Esto significaría que macOS movió o renombró el framework privado.")
    exit(1)
}
print("✓ MultitouchSupport.framework cargado")

// MARK: - Hotkeys

func printHotkeys() {
    let (config, _) = ConfigStore.load()
    let emitter = ActionEmitter()
    emitter.resolve(config: config)
    print("\nAtajos que se dispararían")
    print(String(repeating: "─", count: 60))
    for line in emitter.resolutionLog {
        print("  \(line)")
    }
    print("""

      «default» = el atajo de fábrica de Apple.
      «system»  = leído de com.apple.symbolichotkeys, o sea que lo remapeaste.
      «config override» = lo forzaste tú en config.json.
    """)
}

if hotkeysOnly {
    printHotkeys()
    exit(0)
}

// MARK: - Devices

let devices = MultitouchBridge.devices()
print("\nDispositivos multitouch: \(devices.count)")
print(String(repeating: "─", count: 60))

for (index, device) in devices.enumerated() {
    let family = device.familyID.map(String.init) ?? "?"
    print("""
      [\(index)] familyID \(family) · \(device.isBuiltIn ? "integrado" : "externo") · superficie \(device.describedSize)
           ¿parece Magic Mouse? \(device.looksLikeMagicMouse ? "sí" : "no")
    """)
}

if devices.isEmpty {
    print("  (ninguno — ¿está conectado el Magic Mouse?)")
    exit(1)
}

let candidates = devices.filter { $0.looksLikeMagicMouse }
if candidates.isEmpty {
    print("""

    ⚠️  Ningún dispositivo encaja con la heurística «externo + sensor más alto que ancho».
       Apunta el familyID del Magic Mouse de la lista de arriba: con eso ajusto
       la selección en vez de adivinar.
    """)
}

if devicesOnly { exit(0) }

printHotkeys()

// MARK: - Live frames

/// Rolling state, so the probe can answer the two questions that actually matter
/// in phase 0: does the decode look sane, and which way does y grow.
final class ProbeState {
    static let shared = ProbeState()

    private let lock = NSLock()
    private var lastPrint: CFAbsoluteTime = 0
    private var lastCount = -1
    private var rawDumped = 0

    var maxFingersSeen = 0
    var suspiciousFrames = 0
    var totalFrames = 0

    func shouldPrint(count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if count != lastCount || now - lastPrint > 0.12 {
            lastCount = count
            lastPrint = now
            return true
        }
        return false
    }

    func shouldDumpRaw() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard rawDumped < 3 else { return false }
        rawDumped += 1
        return true
    }
}

private func probeCallback(
    device: MultitouchBridge.DeviceRef?,
    touchData: UnsafeRawPointer?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32
) -> Int32 {
    guard let touchData, numTouches > 0 else { return 0 }
    let touches = TouchDecoder.decode(touchData, count: numTouches)
    let down = touches.filter { $0.state.isDown }

    let state = ProbeState.shared
    state.totalFrames += 1
    state.maxFingersSeen = max(state.maxFingersSeen, down.count)

    // If the struct layout ever moves, normalized coordinates are the first
    // thing to go obviously wrong.
    let sane = touches.allSatisfy { $0.x > -0.5 && $0.x < 1.5 && $0.y > -0.5 && $0.y < 1.5 }
    if !sane { state.suspiciousFrames += 1 }

    if wantsRaw, !sane || state.shouldDumpRaw() {
        print("  raw[0]: \(TouchDecoder.rawBytes(touchData, index: 0))")
    }

    guard state.shouldPrint(count: down.count) else { return 0 }

    if down.isEmpty {
        print("· 0 dedos")
        return 0
    }

    var cx: Float = 0
    var cy: Float = 0
    for touch in down { cx += touch.x; cy += touch.y }
    cx /= Float(down.count)
    cy /= Float(down.count)

    let detail = down
        .map { String(format: "#%d(%.2f,%.2f)", $0.id, $0.x, $0.y) }
        .joined(separator: " ")

    print(String(format: "· %d dedos  centro(%.3f, %.3f)  %@%@",
                 down.count, cx, cy, detail, sane ? "" : "   ⚠️ valores fuera de rango"))
    return 0
}

let externals = devices.filter { !$0.isBuiltIn }
let listenTo = candidates.isEmpty ? externals : candidates
guard !listenTo.isEmpty else {
    print("\nNo hay ningún dispositivo externo al que escuchar.")
    exit(1)
}

for device in listenTo {
    MultitouchBridge.start(device.ref, callback: probeCallback)
}

print("""

Escuchando \(listenTo.count) dispositivo(s)
\(String(repeating: "─", count: 60))

Qué necesito que compruebes:

  1. Apoya tres dedos en el mouse. ¿Llega a decir «3 dedos»? ¿Se mantiene
     estable o parpadea a 2?
  2. Desliza los tres dedos HACIA ADELANTE (lejos de ti). ¿El segundo número
     del centro sube o baja?
       · sube  → invertY: false  (el valor por defecto está bien)
       · baja  → invertY: true   (hay que cambiarlo en config.json)
  3. Fíjate en cuánto cambia ese número de un extremo al otro del recorrido
     cómodo. Eso me dice si swipeThreshold 0.09 es razonable o hay que bajarlo.
  4. Si aparece «valores fuera de rango», el layout de la struct cambió en tu
     macOS: pásame la salida de --raw.

Ctrl-C para salir.

""")

signal(SIGINT) { _ in
    let state = ProbeState.shared
    print("""

    Resumen
      frames: \(state.totalFrames)
      máximo de dedos visto a la vez: \(state.maxFingersSeen)
      frames con valores sospechosos: \(state.suspiciousFrames)
    """)
    exit(0)
}

CFRunLoopRun()
