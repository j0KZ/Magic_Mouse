import AppKit
import ApplicationServices
import MagicMouseKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Activado", action: #selector(toggleEnabled), keyEquivalent: "")
    private var watchdog: Timer?
    private var lastGesture: String?
    private var lastStartResult: Engine.StartResult?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        Engine.shared.onGesture = { [weak self] direction, action in
            guard let self else { return }
            self.lastGesture = "\(direction.rawValue) → \(action.rawValue)"
            if let result = self.lastStartResult {
                StatusReport.write(config: Engine.shared.currentConfig,
                                   result: result, lastGesture: self.lastGesture)
            }

            self.refreshStatus()
        }

        // Arrancar ANTES de avisar de nada. Un `runModal` para el run loop, así
        // que pedir permisos primero dejaba la app viva, con su icono puesto y
        // sin motor detrás — indistinguible desde fuera de que no funcione. Y
        // sin `estado.txt`, que es justo el archivo que lo habría explicado.
        startEngine()
        startWatchdog()

        // Ahora sí, sin bloquear: el aviso va después de que haya algo que
        // contar sobre por qué no funciona.
        DispatchQueue.main.async { [weak self] in
            self?.reportMissingPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdog?.invalidate()
        Engine.shared.stop()
    }

    // MARK: - Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "computermouse",
                                           accessibilityDescription: "Magic Mouse Gestures")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        enabledItem.target = self
        menu.addItem(enabledItem)

        let shortcuts = NSMenuItem(title: "Atajos resueltos…", action: #selector(showShortcuts), keyEquivalent: "")
        shortcuts.target = self
        menu.addItem(shortcuts)

        menu.addItem(.separator())

        let reload = NSMenuItem(title: "Recargar configuración", action: #selector(reload), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let open = NSMenuItem(title: "Abrir config.json", action: #selector(openConfig), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        refreshStatus()
    }

    private func refreshStatus() {
        let config = Engine.shared.currentConfig
        let devices = Engine.shared.attachedDeviceCount

        var lines: [String] = []
        lines.append(devices == 0 ? "Sin Magic Mouse" : "\(devices) dispositivo(s) · \(config.fingers) dedos")
        if let lastGesture { lines.append("último: \(lastGesture)") }
        statusLine.title = lines.joined(separator: " · ")

        enabledItem.state = config.enabled ? .on : .off
        statusItem.button?.appearsDisabled = !config.enabled || devices == 0
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        var config = Engine.shared.currentConfig
        config.enabled.toggle()
        try? ConfigStore.save(config)
        Engine.shared.start(config: config)
        refreshStatus()
    }

    @objc private func reload() {
        startEngine()
    }

    @objc private func openConfig() {
        // Make sure the file exists before asking the Finder to reveal it.
        _ = ConfigStore.load()
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
    }

    @objc private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Atajos que se van a disparar"
        let resolution = Engine.shared.shortcutResolution
        alert.informativeText = resolution.isEmpty
            ? "Todavía no se han resuelto."
            : resolution.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Engine

    private func startEngine() {
        let (config, configError) = ConfigStore.load()
        let result = Engine.shared.start(config: config)

        var problems = result.warnings
        if let configError { problems.insert(configError, at: 0) }

        if !problems.isEmpty {
            NSLog("[MagicMouseGestures] %@", problems.joined(separator: " | "))
        }
        StatusReport.write(config: config, result: result, lastGesture: lastGesture)
        lastStartResult = result
        refreshStatus()
    }

    /// The Magic Mouse disappears from the multitouch device list when it sleeps
    /// or drops off Bluetooth, and does not come back on its own. Re-attach when
    /// the device list stops matching what we're listening to.
    ///
    /// It also picks up a permission granted after launch, which is the normal
    /// case and not the exception: nobody grants Accessibility before first
    /// running an app. Without this the engine starts once, the scroll tap fails
    /// for want of a permission that arrives a minute later, and nothing ever
    /// retries — the gesture fires while the scroll it was meant to replace keeps
    /// happening underneath. That is exactly how this looked when it was broken.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Against the devices the selection would match, not every device:
            // the built-in trackpad is always listed and never chosen, so the
            // raw count would restart the engine forever while the mouse is away.
            let available = Engine.shared.selectableDeviceCount
            let attached = Engine.shared.attachedDeviceCount

            if available > 0 && attached == 0 {
                self.startEngine()
            } else if available == 0 && attached > 0 {
                Engine.shared.stop()
                self.refreshStatus()
            } else if self.suppressorShouldBeRunningButIsNot() {
                self.startEngine()
            }
        }
    }

    /// Only retry once the permission is actually there, so a Mac where it was
    /// refused doesn't restart the engine every five seconds for ever.
    private func suppressorShouldBeRunningButIsNot() -> Bool {
        let config = Engine.shared.currentConfig
        guard config.suppressScroll || config.freezeCursorDuringGesture else { return false }
        return AXIsProcessTrusted() && !Engine.shared.suppressorIsRunning
    }

    // MARK: - Permissions

    /// Un solo aviso, después de arrancar, y solo si de verdad falta algo.
    private func reportMissingPermissions() {
        let accessibility = AXIsProcessTrusted()
        let input = InputMonitoring.status == .granted
        if accessibility && input { return }

        if !accessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if !input { _ = InputMonitoring.request() }

        var faltan: [String] = []
        if !accessibility { faltan.append("· Accesibilidad — para disparar los atajos") }
        if !input { faltan.append("· Monitorización de entrada — para leer los dedos") }

        let explicacion = """

        Ajustes del Sistema → Privacidad y seguridad, activa MagicMouseGestures \
        en cada uno, y vuelve a abrir la app.

        Si ya aparece marcada, desmárcala y vuelve a marcarla: al recompilar \
        cambia la identidad del binario y macOS invalida el permiso sin decirlo.
        """

        let alert = NSAlert()
        alert.messageText = faltan.count == 1 ? "Falta un permiso" : "Faltan dos permisos"
        alert.informativeText = faltan.joined(separator: "\n") + "\n" + explicacion
        alert.addButton(withTitle: !accessibility ? "Abrir Accesibilidad" : "Abrir Monitorización")
        alert.addButton(withTitle: "Ahora no")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            let panel = !accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + panel) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
