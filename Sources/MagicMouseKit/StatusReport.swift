import Foundation
import ApplicationServices

/// What the app knows about itself, written to disk on every engine start.
///
/// Every failure this app can have looks the same from outside — three fingers
/// just scroll — and the menu bar, which is where the answer lives, is a place
/// someone has to find and read back. So the app states its case in a file
/// instead: permissions, devices, whether the scroll tap came up, and what it
/// last recognized.
public enum StatusReport {

    public static var url: URL { ConfigStore.directory.appendingPathComponent("estado.txt") }

    public static func write(config: Config,
                             result: Engine.StartResult,
                             lastGesture: String?) {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("MagicMouseGestures — estado \(formatter.string(from: Date()))")
        lines.append("pid \(ProcessInfo.processInfo.processIdentifier)")
        lines.append("")
        lines.append("Accesibilidad:              \(AXIsProcessTrusted() ? "concedida" : "FALTA")")
        lines.append("Monitorización de entrada:  \(InputMonitoring.status.described)")
        lines.append("Dispositivos multitouch:    \(MultitouchBridge.devices().count)")
        lines.append("Enganchados:                \(result.deviceCount)")
        // Del motor, no de `result`: el resultado del arranque envejece, y este
        // archivo se reescribe con cada gesto. Decía «NO» mucho después de que
        // el tap hubiera subido, que es justo la clase de dato que hace perder
        // una hora persiguiendo un fallo que ya no existe.
        lines.append("Supresor de scroll:         \(Engine.shared.suppressorIsRunning ? "activo" : "NO")")
        lines.append("")
        lines.append("Ajuste: \(config.fingers) dedos · umbral \(config.swipeThreshold) / \(config.swipeWindowMs) ms")
        lines.append("Último gesto: \(lastGesture ?? "ninguno todavía")")
        if !result.warnings.isEmpty {
            lines.append("")
            lines.append("Avisos:")
            for warning in result.warnings { lines.append("  · \(warning)") }
        }

        let text = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: ConfigStore.directory,
                                                 withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
