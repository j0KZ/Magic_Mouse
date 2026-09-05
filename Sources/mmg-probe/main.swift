import Foundation
import ApplicationServices
import CoreGraphics
import MagicMouseKit

// A diagnostic. Everything here only listens — devices, contacts, the recognizer,
// the keyboard sniffer — so it is safe to leave running while you experiment with
// the mouse. The one exception is `--emit`, which posts a shortcut on purpose, to
// tell "the gesture wasn't recognized" apart from "the shortcut had no effect".
// Those are two different failures with identical symptoms.

// Line-buffered on purpose: piped into `tee` or redirected to a file, the
// default block buffering holds several seconds of frames hostage, and loses
// them entirely if the process is killed rather than exiting cleanly.
setvbuf(stdout, nil, _IOLBF, 0)

let argv = Array(CommandLine.arguments.dropFirst())
let args = Set(argv)
let wantsRaw = args.contains("--raw")
let devicesOnly = args.contains("--devices")
let hotkeysOnly = args.contains("--hotkeys")
let wantsCalibrate = args.contains("--calibrate")
let wantsApply = args.contains("--apply")
let wantsLive = args.contains("--live")
let wantsSniff = args.contains("--sniff")

func optionValue(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

let strokesPerStage = max(1, optionValue("--strokes").flatMap(Int.init) ?? 3)
let calibrationFingers = max(1, min(5, optionValue("--fingers").flatMap(Int.init) ?? 3))
let calibrationOut = optionValue("--out") ?? "build/calibration.json"
let forcedDeviceIndex = optionValue("--device").flatMap(Int.init)

if args.contains("--help") || args.contains("-h") {
    print("""
    mmg-probe — diagnóstico de MagicMouseGestures

      (sin argumentos)  lista dispositivos y muestra los contactos en vivo
      --devices         lista los dispositivos multitouch y sale
      --hotkeys         muestra qué atajo se dispararía para cada acción y sale
      --raw             además, vuelca los 96 bytes crudos del primer contacto
      --calibrate       mide unos cuantos deslizamientos y deduce invertY,
                        invertX y swipeThreshold en vez de que los leas a ojo
      --strokes N       trazos por eje durante la calibración (3)
      --fingers N       dedos que se esperan durante la calibración (3)
      --out RUTA        dónde dejar el informe JSON (build/calibration.json)
      --device N        escucha el dispositivo N de la lista en vez de elegirlo
                        solo — útil para contrastar contra el trackpad interno
      --record RUTA     graba cada frame a un archivo mientras escucha
      --replay RUTA     pasa un archivo grabado por el reconocedor y dice qué
                        habría disparado — no necesita ni mouse ni permisos
      --threshold N     con --replay, prueba otro swipeThreshold
      --window N        con --replay, prueba otra ventana en ms
      --apply           escribe lo medido en config.json al terminar
      --sniff           escucha el teclado y vuelca los bits exactos de cada
                        pulsación — para comparar un atajo real con uno fabricado
      --live            corre el reconocedor real sobre los dedos en vivo y
                        avisa cuándo dispararía — NO inyecta, solo diagnostica
      --help            esto

    No inyecta ningún evento. Ctrl-C para salir.
    """)
    exit(0)
}

// MARK: - Emisión de prueba (diagnóstico)
//
// Publica el atajo a mano para separar «el gesto no se reconoce» de «el atajo
// no hace efecto». Son dos fallos distintos con el mismo síntoma.

/// ¿Está Mission Control en pantalla?
///
/// Se nota en la lista de ventanas: el Dock deja de tener sus dos o tres
/// ventanas de siempre y pasa a tener una por cada ventana de la pantalla, para
/// dibujar la rejilla. Contarlas evita tener que preguntarle a nadie si vio algo.
func ventanasDelDock() -> Int {
    let opciones: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let lista = CGWindowListCopyWindowInfo(opciones, kCGNullWindowID) as? [[String: Any]]
    else { return -1 }
    return lista.filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock" }.count
}

if let variante = optionValue("--emit") {
    let trusted = AXIsProcessTrusted()
    print(trusted ? "✓ Accesibilidad: concedida a este binario"
                  : "✗ Accesibilidad: FALTA — sin ella los eventos se descartan en silencio")
    guard trusted else { exit(1) }

    let ctrl: CGKeyCode = 59          // kVK_Control
    let up: CGKeyCode = 126           // flecha arriba
    let source = CGEventSource(stateID: .hidSystemState)

    func post(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags, tap: CGEventTapLocation) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: tap)
    }

    let antes = ventanasDelDock()
    print("  ventanas del Dock antes: \(antes)")
    Thread.sleep(forTimeInterval: 1)

    switch variante {
    case "a":
        // Lo que hace hoy ActionEmitter: solo la tecla, con el flag puesto.
        post(up, true, .maskControl, tap: .cghidEventTap)
        post(up, false, .maskControl, tap: .cghidEventTap)
    case "b":
        // Control como tecla de verdad, alrededor de la flecha.
        post(ctrl, true, .maskControl, tap: .cghidEventTap)
        post(up, true, .maskControl, tap: .cghidEventTap)
        post(up, false, .maskControl, tap: .cghidEventTap)
        post(ctrl, false, [], tap: .cghidEventTap)
    case "real":
        // El camino de verdad: el mismo ActionEmitter que usa la app, con la
        // misma configuración. Probar una variante a mano solo demuestra que la
        // técnica sirve; esto demuestra que el código que se instala la usa.
        let emisor = ActionEmitter()
        emisor.resolve(config: ConfigStore.load().config)
        emisor.perform(.missionControl)
    case "d":
        // Los bits que lleva de verdad una flecha de teclado Mac: fn y
        // numericPad además de control. Sin ellos el evento llega pero el
        // WindowServer no lo reconoce como el atajo registrado.
        let reales: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        post(ctrl, true, [.maskControl, .maskNonCoalesced], tap: .cghidEventTap)
        post(up, true, reales, tap: .cghidEventTap)
        post(up, false, reales, tap: .cghidEventTap)
        post(ctrl, false, .maskNonCoalesced, tap: .cghidEventTap)
    case "e":
        // Igual pero sin tocar la tecla control, solo los flags.
        let reales: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        post(up, true, reales, tap: .cghidEventTap)
        post(up, false, reales, tap: .cghidEventTap)
    case "c":
        // Igual que b, pero por el tap de sesión.
        post(ctrl, true, .maskControl, tap: .cgSessionEventTap)
        post(up, true, .maskControl, tap: .cgSessionEventTap)
        post(up, false, .maskControl, tap: .cgSessionEventTap)
        post(ctrl, false, [], tap: .cgSessionEventTap)
    default:
        print("  variantes: a (solo flags), b (control real), c (control real por sesión)")
        exit(1)
    }
    Thread.sleep(forTimeInterval: 1.2)
    let despues = ventanasDelDock()
    print("  ventanas del Dock después: \(despues)")
    if despues > antes + 1 {
        print("  ✅ Mission Control SE ABRIÓ con la variante \(variante)")
        // Cerrarlo, para no dejar la pantalla ocupada.
        post(53, true, [], tap: .cghidEventTap)   // esc
        post(53, false, [], tap: .cghidEventTap)
    } else {
        print("  ✗ no se abrió con la variante \(variante)")
    }
    exit(0)
}

// MARK: - Espía de teclado (diagnóstico)
//
// Un atajo fabricado y uno real pueden verse iguales y no serlo: las flechas de
// un teclado Mac llevan bits que nadie recuerda poner a mano. En vez de
// adivinar cuáles, se mira el evento de verdad.

if wantsSniff {
    guard AXIsProcessTrusted() else {
        print("✗ Accesibilidad: FALTA — sin ella no se puede escuchar el teclado"); exit(1)
    }

    func describe(_ flags: CGEventFlags) -> String {
        var parts: [String] = []
        let known: [(CGEventFlags, String)] = [
            (.maskControl, "control"), (.maskAlternate, "option"), (.maskShift, "shift"),
            (.maskCommand, "command"), (.maskSecondaryFn, "fn"), (.maskNumericPad, "numericPad"),
            (.maskAlphaShift, "capsLock"), (.maskHelp, "help"), (.maskNonCoalesced, "nonCoalesced"),
        ]
        for (flag, name) in known where flags.contains(flag) { parts.append(name) }
        return parts.isEmpty ? "(ninguno)" : parts.joined(separator: "+")
    }

    func sniffCallback(proxy: CGEventTapProxy, type: CGEventType,
                       event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return nil
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let kind = type == .keyDown ? "keyDown " : (type == .keyUp ? "keyUp   " : "flags   ")
        print(String(format: "  %@ keycode %3d   flags 0x%08X   %@",
                     kind, code, UInt64(flags.rawValue), describe(flags)))
        return Unmanaged.passUnretained(event)
    }

    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
              | CGEventMask(1 << CGEventType.keyUp.rawValue)
              | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: sniffCallback, userInfo: nil) else {
        print("✗ No se pudo crear el tap de teclado"); exit(1)
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    print("""

    Espía de teclado — solo mira, no modifica nada
    \(String(repeating: "─", count: 60))
    Pulsa Ctrl+↑ con el teclado. Aquí saldrán los bits exactos del evento real.
    """)
    signal(SIGINT) { _ in print("\n  fin."); exit(0) }
    CFRunLoopRun()
}

// MARK: - Replay

//
// Deliberately ahead of every hardware check: the whole point is to re-run the
// recognizer over swipes that were already captured, on any machine, with no
// mouse and no permissions.

if let replayPath = optionValue("--replay") {
    var config = ConfigStore.load().config
    config.fingers = calibrationFingers
    if let threshold = optionValue("--threshold").flatMap(Float.init) {
        config.swipeThreshold = threshold
    }
    if let window = optionValue("--window").flatMap(Int.init) {
        config.swipeWindowMs = window
    }

    let frames: [FrameLog.Frame]
    do {
        frames = try FrameLog.read(path: replayPath)
    } catch {
        print("No se pudo leer \(replayPath): \(error.localizedDescription)")
        exit(1)
    }
    guard let first = frames.first else {
        print("\(replayPath) no tiene ni un frame.")
        exit(1)
    }

    print("""
    Reproduciendo \(frames.count) frames de \(replayPath)
    \(String(repeating: "─", count: 60))
      dedos \(config.fingers)   umbral \(String(format: "%.3f", config.swipeThreshold))/\(config.swipeWindowMs)ms   dominancia \(String(format: "%.2f", config.axisDominance))
      invertY \(config.invertY)   invertX \(config.invertX)   gracia \(config.dropoutGraceMs) ms
    """)

    let recognizer = GestureRecognizer(config: config)
    let grace = Double(config.dropoutGraceMs) / 1000

    var strokes = 0
    var strokesAtTarget = 0
    var fired = 0
    var extraFires = 0
    var firedThisStroke = false
    var peakThisStroke = 0
    var inStroke = false

    // Counted exactly the way the recognizer draws stroke boundaries: a frame
    // with no finger down closes the stroke, and so does a gap longer than the
    // dropout grace. Anything else and this report would be describing a
    // different recognizer from the one that just ran.
    func closeStroke() {
        guard inStroke else { return }
        strokes += 1
        if peakThisStroke >= config.fingers { strokesAtTarget += 1 }
        if firedThisStroke { fired += 1 }
        inStroke = false
        peakThisStroke = 0
        firedThisStroke = false
    }

    var lastDownAt: Double?

    for frame in frames {
        let touches = frame.touches
        let downCount = touches.filter { $0.state.isDown }.count

        if downCount == 0 {
            closeStroke()
            lastDownAt = nil
        } else {
            if let last = lastDownAt, frame.t - last > grace { closeStroke() }
            inStroke = true
            lastDownAt = frame.t
            peakThisStroke = max(peakThisStroke, downCount)
        }

        if let recognition = recognizer.handle(touches: touches, timestamp: frame.t) {
            if firedThisStroke { extraFires += 1 }
            firedThisStroke = true
            let action = config.action(for: recognition.direction)
            print(String(format: "  #%2d  t+%6.2f  %@ → %@",
                         strokes + 1, frame.t - first.t,
                         recognition.direction.rawValue, action.rawValue))
        }
    }
    closeStroke()

    print("""

      Trazos: \(strokes)   ·   con \(config.fingers) dedos: \(strokesAtTarget)   ·   dispararon: \(fired)
    """)
    if strokesAtTarget > fired {
        print("      \(strokesAtTarget - fired) trazo(s) llegaron a \(config.fingers) dedos y no dispararon.")
    }
    if extraFires > 0 {
        print("      ⚠︎ \(extraFires) disparo(s) de más dentro de un mismo trazo.")
    }
    exit(0)
}

// MARK: - Live recognizer (diagnostic, never injects)

if wantsLive {
    guard MultitouchBridge.isAvailable else {
        print("✗ No se pudo cargar MultitouchSupport.framework"); exit(1)
    }
    let access = InputMonitoring.status
    print(access == .granted
        ? "✓ Monitorización de entrada: concedida"
        : "⚠️  Monitorización de entrada: \(access.described) — sin ella no llega ningún frame")

    var cfg = ConfigStore.load().config
    if let t = optionValue("--threshold").flatMap(Float.init) { cfg.swipeThreshold = t }
    if let w = optionValue("--window").flatMap(Int.init) { cfg.swipeWindowMs = w }

    let all = MultitouchBridge.devices()
    let pick = all.filter { $0.looksLikeMagicMouse }.first ?? all.first { !$0.isBuiltIn }
    guard let device = pick else { print("No hay Magic Mouse."); exit(1) }

    final class Box {
        static var rec: GestureRecognizer!
        static var cfg = Config()
        static var lastEngaged = false
        static var recorder: FrameLog.Recorder?
    }
    Box.rec = GestureRecognizer(config: cfg); Box.cfg = cfg

    // Grabar mientras se diagnostica en vivo: lo que pase durante la prueba se
    // puede volver a pasar por el reconocedor con otros umbrales, en vez de
    // afinar de oído sobre un recuerdo.
    if let path = optionValue("--record") {
        do {
            Box.recorder = try FrameLog.Recorder(path: path)
            print("  grabando en \(path)")
        } catch {
            print("  ⚠️  no se pudo grabar en \(path): \(error.localizedDescription)")
        }
    }

    // Sin esto la salida se queda en el búfer cuando no va a una terminal, y un
    // diagnóstico que no se ve en el momento no sirve de mucho.
    setvbuf(stdout, nil, _IOLBF, 0)

    func liveCallback(device: MultitouchBridge.DeviceRef?, touchData: UnsafeRawPointer?,
                      numTouches: Int32, timestamp: Double, frame: Int32) -> Int32 {
        let touches: [Touch] = (touchData != nil && numTouches > 0)
            ? TouchDecoder.decode(touchData!, count: numTouches) : []
        let down = touches.filter { $0.state.isDown }.count
        Box.recorder?.write(timestamp: timestamp, touches: touches)
        if let r = Box.rec.handle(touches: touches, timestamp: timestamp) {
            let action = Box.cfg.action(for: r.direction)
            print(String(format: "  🔥 DISPARARÍA  %@ → %@   (%d dedos)", r.direction.rawValue, action.rawValue, r.fingers))
        } else if Box.rec.isEngaged != Box.lastEngaged {
            print(Box.rec.isEngaged ? "  · \(down) dedos abajo (siguiendo…)" : "  · mano levantada")
            Box.lastEngaged = Box.rec.isEngaged
        }
        return 0
    }

    print("""

    Reconocedor en vivo — umbral \(String(format: "%.2f", cfg.swipeThreshold))/\(cfg.swipeWindowMs)ms, \(cfg.fingers) dedos
    \(String(repeating: "─", count: 60))
    Haz flicks secos de 3 dedos. Aquí verás «DISPARARÍA» cuando el gesto cuente.
    No se inyecta nada. Ctrl-C para salir.
    """)
    guard MultitouchBridge.start(device.ref, callback: liveCallback) else {
        print("No se pudo enganchar el dispositivo."); exit(1)
    }
    signal(SIGINT) { _ in
        Box.recorder?.close()
        if let recorder = Box.recorder { print("\n  \(recorder.frameCount) frames grabados.") }
        print("  fin.")
        exit(0)
    }
    CFRunLoopRun()
}

// MARK: - Framework

guard MultitouchBridge.isAvailable else {
    print("✗ No se pudo cargar MultitouchSupport.framework")
    print("  \(MultitouchBridge.loadError ?? "sin detalle")")
    print("  Esto significaría que macOS movió o renombró el framework privado.")
    exit(1)
}
print("✓ MultitouchSupport.framework cargado")

// MARK: - Permission
//
// Checked before anything else, because every other symptom downstream — no
// contacts, no three fingers, a gesture that never fires — looks identical when
// the real problem is that macOS is quietly dropping the frames.

let access = InputMonitoring.status
if access == .granted {
    print("✓ Monitorización de entrada: concedida")
} else {
    print("""
    ⚠️  Monitorización de entrada: \(access.described)

       Sin ese permiso todo lo demás parece ir bien — el framework carga, los
       dispositivos aparecen, MTDeviceStart devuelve éxito — y macOS
       simplemente no entrega ni un frame. Cero contactos, sin ningún error.
    """)
    _ = InputMonitoring.request()
    print("""
       Ajustes del Sistema → Privacidad y seguridad → Monitorización de entrada,
       y activa ahí «\(InputMonitoring.responsibleProcess)». Luego vuelve a
       lanzar esto: el permiso solo se lee al arrancar el proceso.
    """)
}

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

// MARK: - Symbols

let symbols = MultitouchBridge.symbolReport()
let missing = symbols.filter { !$0.found }
if missing.isEmpty {
    print("✓ Símbolos privados: los \(symbols.count) resuelven")
} else {
    print("\n⚠️  Símbolos que este macOS ya no exporta:")
    for symbol in missing { print("     \(symbol.name)") }
    print("     Sin ellos la escucha no puede funcionar, y falla en silencio.")
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

// MARK: - Calibration

/// Unlike the live probe this must also see the frames where nothing is down:
/// the lift is what closes a stroke.
private func calibrateCallback(
    device: MultitouchBridge.DeviceRef?,
    touchData: UnsafeRawPointer?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32
) -> Int32 {
    let touches: [Touch]
    if let touchData, numTouches > 0 {
        touches = TouchDecoder.decode(touchData, count: numTouches)
    } else {
        touches = []
    }
    Calibrator.shared.record(touches: touches, timestamp: timestamp)
    return 0
}

func describe(_ report: Calibrator.Report) {
    print("""

    Resultado
    \(String(repeating: "─", count: 60))
    """)

    for axis in report.axes {
        let name = axis.axis == .vertical ? "Vertical (adelante)" : "Horizontal (derecha)"
        print(String(format: """
          %@
            desplazamiento medio  %+.3f
            recorrido  mín %.3f · mediana %.3f · máx %.3f
            coincidencia de signo %.0f %%   ·   fuga al otro eje %.0f %%
            → %@: %@
        """, name, axis.meanDelta, axis.minTravel, axis.medianTravel, axis.maxTravel,
             axis.signAgreement * 100, axis.crossAxisRatio * 100,
             axis.flag, axis.invertRecommended ? "true" : "false"))
    }

    print(String(format: """

      Estabilidad de %d dedos: %.0f %% de los frames con la mano apoyada
      Máximo de dedos ABAJO a la vez: %d
      Máximo de contactos vistos a la vez: %d
      Frames: %d   ·   sospechosos: %d   ·   trazos descartados: %d

      Configuración sugerida
        invertY          %@
        invertX          %@
        swipeThreshold   %.3f      (hoy: 0.09)
        axisDominance    %.2f
    """, report.targetFingers, report.fingerStability * 100, report.maxFingersSeen,
         report.maxContactsSeen, report.framesSeen, report.suspiciousFrames, report.rejectedStrokes,
         report.invertY ? "true" : "false", report.invertX ? "true" : "false",
         report.suggestedThreshold, report.suggestedAxisDominance))

    if !report.notes.isEmpty {
        print("\n  Avisos")
        for note in report.notes { print("    · \(note)") }
    }
}

func writeReport(_ report: Calibrator.Report, to path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        print("\n  Informe completo en \(path)")
    } catch {
        print("\n  No se pudo escribir \(path): \(error.localizedDescription)")
    }
}

func applyReport(_ report: Calibrator.Report) {
    var (config, _) = ConfigStore.load()
    config.invertY = report.invertY
    config.invertX = report.invertX
    config.swipeThreshold = report.suggestedThreshold
    config.axisDominance = report.suggestedAxisDominance
    config.fingers = report.targetFingers
    do {
        try ConfigStore.save(config)
        print("  Escrito en \(ConfigStore.url.path)")
    } catch {
        print("  No se pudo escribir la configuración: \(error.localizedDescription)")
    }
}

if wantsCalibrate {
    let preferred = forcedDeviceIndex.flatMap { devices.indices.contains($0) ? devices[$0] : nil }
    guard let device = preferred ?? candidates.first ?? devices.first(where: { !$0.isBuiltIn }) else {
        print("\nNo hay ningún dispositivo externo que calibrar.")
        exit(1)
    }

    print("""

    Calibración — \(strokesPerStage) trazos por eje, \(calibrationFingers) dedos
    \(String(repeating: "─", count: 60))

    Apoya los dedos, desliza, y LEVANTA la mano: el levantar es lo que cierra
    cada medición. Tómate el tiempo que quieras entre trazo y trazo, y hazlos
    del tamaño que te resulte cómodo — es justo eso lo que estoy midiendo.

    No se inyecta ningún evento.
    """)

    let calibrator = Calibrator.shared

    calibrator.onStageChange = { stage in
        guard let stage else { return }
        print("\n▸ \(stage.instruction) — \(strokesPerStage) veces\n")
    }

    calibrator.onStroke = { _, stroke, index, reason in
        if let reason {
            print(String(format: "  ✗ descartado: %@  (máx %d dedos, %.2f s)",
                         reason, stroke.maxFingers, stroke.duration))
        } else {
            print(String(format: "  %d/%d  Δx %+.3f  Δy %+.3f   ·   %d dedos, %.2f s, %d caída(s)",
                         index, strokesPerStage, stroke.dx, stroke.dy,
                         stroke.maxFingers, stroke.duration, stroke.dropouts))
        }
    }

    calibrator.onFinish = { report in
        describe(report)
        writeReport(report, to: calibrationOut)
        if wantsApply { applyReport(report) }
        exit(0)
    }

    let family = device.familyID.map(String.init) ?? "?"
    calibrator.begin(stages: [.forward, .rightward],
                     targetFingers: calibrationFingers,
                     strokesPerStage: strokesPerStage,
                     device: "familyID \(family) · \(device.describedSize)")

    guard MultitouchBridge.start(device.ref, callback: calibrateCallback) else {
        print("\nNo se pudo empezar a escuchar el dispositivo.")
        exit(1)
    }

    // A stage that never fills would otherwise hang forever waiting for a hand
    // that isn't coming — and "the sensor never gives me three fingers" is a
    // result too, so move on and report it rather than waiting it out.
    let stageTimeout: Double = 30
    let ticker = Timer(timeInterval: 2, repeats: true) { _ in
        guard CFAbsoluteTimeGetCurrent() - Calibrator.shared.lastAcceptedAt > stageTimeout else { return }
        print("\n  (sin trazos válidos en \(Int(stageTimeout)) s — sigo con el eje siguiente)")
        Calibrator.shared.timeoutStage()
    }
    RunLoop.current.add(ticker, forMode: .common)

    signal(SIGINT) { _ in
        print("\n  (interrumpido — informo con lo que haya)")
        Calibrator.shared.finishNow()
        exit(0)
    }

    CFRunLoopRun()
}

printHotkeys()

// MARK: - Live frames

/// Rolling state, so the probe can answer the two questions that actually matter
/// in phase 0: does the decode look sane, and which way does y grow.
final class ProbeState {
    static let shared = ProbeState()

    private let lock = NSLock()
    private var lastPrint: CFAbsoluteTime = 0
    private var lastSignature = ""
    private var rawDumped = 0

    var maxFingersSeen = 0
    var maxContactsSeen = 0
    var suspiciousFrames = 0
    var totalFrames = 0
    /// How often each contact state showed up, so an undercount can be told
    /// apart from a misdecode: if the mouse reports three contacts and only one
    /// counts as "down", the fault is in the state filter, not the sensor.
    var stateHistogram: [Int32: Int] = [:]

    func shouldPrint(signature: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if signature != lastSignature || now - lastPrint > 0.25 {
            lastSignature = signature
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

var frameRecorder: FrameLog.Recorder?

private func probeCallback(
    device: MultitouchBridge.DeviceRef?,
    touchData: UnsafeRawPointer?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32
) -> Int32 {
    guard let touchData, numTouches > 0 else { return 0 }
    let touches = TouchDecoder.decode(touchData, count: numTouches)
    frameRecorder?.write(timestamp: timestamp, touches: touches)
    let down = touches.filter { $0.state.isDown }

    let state = ProbeState.shared
    state.totalFrames += 1
    state.maxFingersSeen = max(state.maxFingersSeen, down.count)
    state.maxContactsSeen = max(state.maxContactsSeen, touches.count)
    for touch in touches { state.stateHistogram[touch.state.rawValue, default: 0] += 1 }

    // If the struct layout ever moves, normalized coordinates are the first
    // thing to go obviously wrong.
    let sane = touches.allSatisfy { $0.x > -0.5 && $0.x < 1.5 && $0.y > -0.5 && $0.y < 1.5 }
    if !sane { state.suspiciousFrames += 1 }

    if wantsRaw, !sane || state.shouldDumpRaw() {
        print("  raw[0]: \(TouchDecoder.rawBytes(touchData, index: 0))")
    }

    guard state.shouldPrint(signature: "\(touches.count)/\(down.count)") else { return 0 }

    if touches.isEmpty {
        print("· nada")
        return 0
    }

    // Every contact, not just the ones that count: a finger the sensor sees but
    // reports as hovering is a very different problem from one it never sees.
    let detail = touches
        .map { String(format: "#%d %@(%.2f,%.2f)", $0.id, stateName($0.state), $0.x, $0.y) }
        .joined(separator: "  ")

    if down.isEmpty {
        print("· \(touches.count) contacto(s), 0 abajo   \(detail)")
        return 0
    }

    var cx: Float = 0
    var cy: Float = 0
    for touch in down { cx += touch.x; cy += touch.y }
    cx /= Float(down.count)
    cy /= Float(down.count)

    print(String(format: "· %d contacto(s), %d abajo  centro(%.3f, %.3f)   %@%@",
                 touches.count, down.count, cx, cy, detail,
                 sane ? "" : "   ⚠️ valores fuera de rango"))
    return 0
}

func stateName(_ state: Touch.State) -> String {
    switch state {
    case .notTouching: return "fuera"
    case .starting:    return "empieza"
    case .hovering:    return "roza"
    case .making:      return "apoya"
    case .touching:    return "ABAJO"
    case .breaking:    return "suelta"
    case .lingering:   return "resta"
    case .leaving:     return "sale"
    }
}

let externals = devices.filter { !$0.isBuiltIn }
var listenTo = candidates.isEmpty ? externals : candidates
if let index = forcedDeviceIndex {
    guard devices.indices.contains(index) else {
        print("\nNo hay ningún dispositivo [\(index)] en la lista.")
        exit(1)
    }
    listenTo = [devices[index]]
    print("\n(forzado al dispositivo [\(index)])")
}
guard !listenTo.isEmpty else {
    print("\nNo hay ningún dispositivo externo al que escuchar.")
    exit(1)
}

if let recordPath = optionValue("--record") {
    do {
        frameRecorder = try FrameLog.Recorder(path: recordPath)
        print("\nGrabando frames en \(recordPath)")
    } catch {
        print("\nNo se pudo grabar en \(recordPath): \(error.localizedDescription)")
        exit(1)
    }
}

var attached = 0
for device in listenTo {
    if MultitouchBridge.start(device.ref, callback: probeCallback) {
        attached += 1
    } else {
        print("⚠️  No se pudo enganchar un dispositivo — falta algún símbolo.")
    }
}
guard attached > 0 else {
    print("\nNo quedó ningún dispositivo enganchado. Sin esto no llega nada.")
    exit(1)
}

print("""

Escuchando \(attached) dispositivo(s)
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
    frameRecorder?.close()
    let state = ProbeState.shared
    let histogram = state.stateHistogram
        .sorted { $0.key < $1.key }
        .map { "\(stateName(Touch.State(rawValue: $0.key) ?? .notTouching))×\($0.value)" }
        .joined(separator: "  ")
    print("""

    Resumen
      frames: \(state.totalFrames)
      máximo de contactos a la vez: \(state.maxContactsSeen)
      máximo de dedos ABAJO a la vez: \(state.maxFingersSeen)
      frames con valores sospechosos: \(state.suspiciousFrames)
      estados vistos: \(histogram)
    """)
    exit(0)
}

CFRunLoopRun()
