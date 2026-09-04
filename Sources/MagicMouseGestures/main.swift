import AppKit
import ApplicationServices
import MagicMouseKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Activado", action: #selector(toggleEnabled), keyEquivalent: "")
    private var watchdog: Timer?
    private var lastGesture: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        guard ensureAccessibility() else { return }
        ensureInputMonitoring()

        Engine.shared.onGesture = { [weak self] direction, action in
            self?.lastGesture = "\(direction.rawValue) → \(action.rawValue)"
            self?.refreshStatus()
        }

        startEngine()
        startWatchdog()
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
        refreshStatus()
    }

    /// The Magic Mouse disappears from the multitouch device list when it sleeps
    /// or drops off Bluetooth, and does not come back on its own. Re-attach when
    /// the device list stops matching what we're listening to.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let available = MultitouchBridge.devices().count
            let attached = Engine.shared.attachedDeviceCount
            if available > 0 && attached == 0 {
                self.startEngine()
            } else if available == 0 && attached > 0 {
                Engine.shared.stop()
                self.refreshStatus()
            }
        }
    }

    // MARK: - Permissions

    /// Input Monitoring is the permission everyone forgets, because nothing
    /// fails loudly without it: MTDeviceStart still succeeds and the device
    /// still lists, but not a single contact frame is delivered. The app is a
    /// different TCC identity from the Terminal that ran mmg-probe, so its own
    /// grant is separate. Ask for it explicitly, or three fingers do nothing.
    private func ensureInputMonitoring() {
        if InputMonitoring.status == .granted { return }

        _ = InputMonitoring.request()

        let alert = NSAlert()
        alert.messageText = "Falta el permiso de Monitorización de entrada"
        alert.informativeText = """
        MagicMouseGestures necesita Monitorización de entrada para leer los dedos         del Magic Mouse. Sin él la app arranca pero no recibe ningún contacto, y         los gestos no hacen nada.

        Ajustes del Sistema → Privacidad y seguridad → Monitorización de entrada →         activa MagicMouseGestures, y vuelve a abrir la app.
        """
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Seguir igual")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        let alert = NSAlert()
        alert.messageText = "Falta el permiso de Accesibilidad"
        alert.informativeText = """
        MagicMouseGestures necesita Accesibilidad para leer los gestos y disparar \
        los atajos del sistema.

        Ajustes del Sistema → Privacidad y seguridad → Accesibilidad → activa \
        MagicMouseGestures, y vuelve a abrir la app.
        """
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Salir")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
