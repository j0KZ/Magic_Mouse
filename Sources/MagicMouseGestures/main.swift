import AppKit
import ApplicationServices
import MagicMouseKit

/// The whole user interface: an icon in the menu bar and what drops out of it.
///
/// Everything here is reachable in two clicks on purpose. The settings that
/// matter — how hard you have to flick, what each direction does — are the ones
/// people actually want to change, and sending them to a JSON file to change a
/// number is not a real answer.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var watchdog: Timer?
    private var lastGesture: (direction: Direction, action: Action)?
    private var lastStartResult: Engine.StartResult?
    private var flashTimer: Timer?

    /// Presets for `swipeThreshold`. 0.06 is what the recordings settled on; the
    /// rest are a slider for hands that flick harder or softer, which on a
    /// surface this small is the difference between "it works" and "it doesn't".
    private static let sensitivities: [(key: String, value: Float)] = [
        ("sensitivity.veryLight", 0.04),
        ("sensitivity.light", 0.05),
        ("sensitivity.normal", 0.06),
        ("sensitivity.firm", 0.08),
        ("sensitivity.veryFirm", 0.10),
    ]

    /// Left and right are missing on purpose: three fingers span the width of
    /// this mouse, so a sideways flick has nowhere to go. Offering the choice
    /// would only promise something that can never fire.
    private static let bindableDirections: [(Direction, String)] = [
        (.up, "gestures.swipeUp"),
        (.down, "gestures.swipeDown"),
    ]

    private static let assignableActions: [Action] = [
        .missionControl, .appExpose, .spaceLeft, .spaceRight, .showDesktop, .launchpad, .none,
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (config, _) = ConfigStore.load()
        L.forcedLanguage = config.language == "auto" ? nil : config.language

        buildStatusItem()

        Engine.shared.onGesture = { [weak self] direction, action in
            guard let self else { return }
            self.lastGesture = (direction, action)
            self.flashIcon()
            if let result = self.lastStartResult {
                StatusReport.write(config: Engine.shared.currentConfig,
                                   result: result, lastGesture: self.describeLastGesture())
            }
            self.rebuildMenu()
        }

        // Start BEFORE warning about anything. A `runModal` stops the run loop,
        // so asking for permissions first left the app alive, with its icon in
        // place and no engine behind it — indistinguishable from broken, and
        // with no `estado.txt` either, which is the file that would have said so.
        startEngine()
        startWatchdog()

        DispatchQueue.main.async { [weak self] in
            self?.reportMissingPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        flashTimer?.invalidate()
        watchdog?.invalidate()
        Engine.shared.stop()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.toolTip = "Magic Mouse Gestures"
        rebuildMenu()
    }

    /// Rebuilt rather than mutated. The menu is small, it is only assembled when
    /// something changed, and a dozen cached outlets to keep in sync is how
    /// checkmarks end up lying about the state.
    /// Fill the icon for a moment when a gesture fires.
    ///
    /// The only feedback that the flick registered. Without it, "the gesture was
    /// not recognized" and "it was recognized and the action did nothing" look
    /// exactly the same from the outside — which is the shape of every bug this
    /// project has had.
    private func flashIcon() {
        flashTimer?.invalidate()
        statusItem.button?.image = MenuBarIcon.activeImage()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.statusItem.button?.image = MenuBarIcon.image()
        }
    }

    private func rebuildMenu() {
        let config = Engine.shared.currentConfig
        let devices = Engine.shared.attachedDeviceCount
        let menu = NSMenu()

        menu.addItem(disabled(devices == 0
            ? localized("status.noDevice")
            : localized("status.connected", config.fingers)))

        if let last = lastGesture {
            menu.addItem(disabled(localized("status.lastGesture",
                                            last.direction.localizedName,
                                            last.action.localizedName)))
        }
        menu.addItem(.separator())

        let enabled = item(localized("menu.enabled"), #selector(toggleEnabled))
        enabled.state = config.enabled ? .on : .off
        menu.addItem(enabled)

        menu.addItem(submenu(localized("menu.sensitivity"), sensitivityMenu(config)))
        menu.addItem(submenu(localized("menu.gestures"), gesturesMenu(config)))

        let suppress = item(localized("menu.suppressScroll"), #selector(toggleSuppressScroll))
        suppress.state = config.suppressScroll ? .on : .off
        menu.addItem(suppress)

        let freeze = item(localized("menu.freezeCursor"), #selector(toggleFreezeCursor))
        freeze.state = config.freezeCursorDuringGesture ? .on : .off
        menu.addItem(freeze)

        menu.addItem(submenu(localized("menu.language"), languageMenu(config)))
        menu.addItem(.separator())
        menu.addItem(submenu(localized("menu.diagnostics"), diagnosticsMenu()))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: localized("menu.quit"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.appearsDisabled = !config.enabled || devices == 0
    }

    private func sensitivityMenu(_ config: Config) -> NSMenu {
        let menu = NSMenu()
        var matched = false
        for (index, preset) in Self.sensitivities.enumerated() {
            let entry = item(localized(preset.key), #selector(setSensitivity(_:)))
            entry.tag = index
            if abs(config.swipeThreshold - preset.value) < 0.001 {
                entry.state = .on
                matched = true
            }
            menu.addItem(entry)
        }
        // Somebody who tuned the value by hand in config.json shouldn't see five
        // unticked presets and conclude the app forgot their setting.
        if !matched {
            menu.addItem(.separator())
            let custom = disabled(localized("sensitivity.custom", Double(config.swipeThreshold)))
            custom.state = .on
            menu.addItem(custom)
        }
        return menu
    }

    private func gesturesMenu(_ config: Config) -> NSMenu {
        let menu = NSMenu()
        for (direction, titleKey) in Self.bindableDirections {
            let submenu = NSMenu()
            for action in Self.assignableActions {
                let entry = item(action.localizedName, #selector(bindAction(_:)))
                entry.representedObject = [direction.rawValue, action.rawValue]
                entry.state = config.action(for: direction) == action ? .on : .off
                submenu.addItem(entry)
            }
            menu.addItem(self.submenu(localized(titleKey), submenu))
        }
        menu.addItem(.separator())
        menu.addItem(disabled(localized("gestures.lateralNote")))
        return menu
    }

    private func languageMenu(_ config: Config) -> NSMenu {
        let menu = NSMenu()
        for code in ["auto", "en", "es"] {
            let entry = item(localized("language.\(code)"), #selector(setLanguage(_:)))
            entry.representedObject = code
            entry.state = config.language == code ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    private func diagnosticsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(localized("menu.shortcuts"), #selector(showShortcuts)))
        menu.addItem(item(localized("menu.openStatus"), #selector(openStatus)))
        menu.addItem(item(localized("menu.openConfig"), #selector(openConfig)))
        menu.addItem(.separator())
        menu.addItem(item(localized("menu.reload"), #selector(reload)))
        return menu
    }

    // MARK: - Menu building helpers

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }

    private func describeLastGesture() -> String? {
        guard let last = lastGesture else { return nil }
        return "\(last.direction.rawValue) → \(last.action.rawValue)"
    }

    // MARK: - Settings

    /// Every change goes through here: write it, restart the engine on the new
    /// value, redraw the menu. One path means the checkmarks cannot drift away
    /// from what is actually running.
    private func apply(_ change: (inout Config) -> Void) {
        var config = Engine.shared.currentConfig
        change(&config)
        try? ConfigStore.save(config)
        startEngine()
    }

    @objc private func toggleEnabled() { apply { $0.enabled.toggle() } }
    @objc private func toggleSuppressScroll() { apply { $0.suppressScroll.toggle() } }
    @objc private func toggleFreezeCursor() { apply { $0.freezeCursorDuringGesture.toggle() } }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        let preset = Self.sensitivities[sender.tag]
        apply { $0.swipeThreshold = preset.value }
    }

    @objc private func bindAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        apply { $0.bindings[pair[0]] = pair[1] }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        apply { $0.language = code }
        L.forcedLanguage = code == "auto" ? nil : code
        rebuildMenu()

        // AppKit caches a fair amount of localized state, so say plainly that a
        // relaunch is needed rather than leaving half the menu in each language.
        let alert = NSAlert()
        alert.messageText = localized("alert.language.title")
        alert.informativeText = localized("alert.language.body")
        alert.addButton(withTitle: localized("alert.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func reload() { startEngine() }

    @objc private func openConfig() {
        _ = ConfigStore.load()
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
    }

    @objc private func openStatus() {
        NSWorkspace.shared.activateFileViewerSelecting([StatusReport.url])
    }

    @objc private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = localized("alert.shortcuts.title")
        let resolution = Engine.shared.shortcutResolution
        alert.informativeText = resolution.isEmpty
            ? localized("alert.shortcuts.empty")
            : resolution.joined(separator: "\n")
        alert.addButton(withTitle: localized("alert.ok"))
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

        lastStartResult = result
        StatusReport.write(config: config, result: result, lastGesture: describeLastGesture())
        rebuildMenu()
    }

    /// The Magic Mouse drops off Bluetooth when it sleeps and does not come back
    /// on its own, so re-attach when the device list stops matching.
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
            // the built-in trackpad is always listed and never chosen, so the raw
            // count would restart the engine every five seconds for ever.
            let available = Engine.shared.selectableDeviceCount
            let attached = Engine.shared.attachedDeviceCount

            if available > 0 && attached == 0 {
                self.startEngine()
            } else if available == 0 && attached > 0 {
                Engine.shared.stop()
                self.rebuildMenu()
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

    /// One warning, after starting, and only if something is genuinely missing.
    private func reportMissingPermissions() {
        let accessibility = AXIsProcessTrusted()
        let input = InputMonitoring.status == .granted
        if accessibility && input { return }

        if !accessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if !input { _ = InputMonitoring.request() }

        var missing: [String] = []
        if !accessibility { missing.append(localized("alert.permissions.accessibility")) }
        if !input { missing.append(localized("alert.permissions.input")) }

        let alert = NSAlert()
        alert.messageText = localized(missing.count == 1
            ? "alert.permissions.one" : "alert.permissions.two")
        alert.informativeText = missing.joined(separator: "\n") + "\n\n"
            + localized("alert.permissions.body")
        alert.addButton(withTitle: localized(!accessibility
            ? "alert.permissions.openAccessibility" : "alert.permissions.openInput"))
        alert.addButton(withTitle: localized("alert.permissions.later"))
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
