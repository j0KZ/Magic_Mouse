import CoreGraphics
import Foundation
import Testing
@testable import MagicMouseKit

/// Pruebas de qué tecla se manda por cada acción. No se publica ningún evento:
/// eso ya es territorio del sistema.
struct ActionEmitterTests {

    /// Sin atajos del sistema, la resolución es determinista: no lee las
    /// preferencias del usuario.
    private static func emitter(_ config: Config) -> ActionEmitter {
        let emitter = ActionEmitter()
        emitter.resolve(config: config)
        return emitter
    }

    @Test("Sin nada configurado se usan los atajos de fábrica")
    func fallbackCombos() {
        var config = Config()
        config.useSystemShortcuts = false
        let emitter = Self.emitter(config)
        #expect(emitter.combo(for: .missionControl) != nil)
        #expect(emitter.combo(for: Action.none) == nil)
    }

    @Test("Lo que se ponga en la configuración manda sobre todo lo demás")
    func overrideWins() {
        var config = Config()
        config.useSystemShortcuts = true      // aun así gana el override
        config.overrides[Action.missionControl.rawValue] =
            KeyComboSpec(keyCode: Int(KeyCodes.f11), modifiers: ["cmd"])

        let emitter = Self.emitter(config)
        #expect(emitter.combo(for: .missionControl)?.keyCode == KeyCodes.f11)
        #expect(emitter.combo(for: .missionControl)?.flags.contains(.maskCommand) == true)
    }

    @Test("El informe dice de dónde salió cada atajo")
    func resolutionLogExplainsItself() {
        // Es lo que imprime `mmg-probe --hotkeys` cuando algo no dispara.
        var config = Config()
        config.useSystemShortcuts = false
        config.overrides[Action.missionControl.rawValue] =
            KeyComboSpec(keyCode: Int(KeyCodes.f11), modifiers: ["cmd"])

        let log = Self.emitter(config).resolutionLog
        #expect(log.contains { $0.contains("missionControl") && $0.contains("config override") })
        #expect(log.contains { $0.contains("(default)") })
    }

    @Test("Los modificadores se leen por su nombre, escrito como sea")
    func modifierNames() {
        #expect(KeyCodes.flags(fromNames: ["cmd"]).contains(.maskCommand))
        #expect(KeyCodes.flags(fromNames: ["COMMAND"]).contains(.maskCommand))
        #expect(KeyCodes.flags(fromNames: ["ctrl", "alt"]) == [.maskControl, .maskAlternate])
        #expect(KeyCodes.flags(fromNames: ["fn"]).contains(.maskSecondaryFn))
    }

    @Test("Un modificador inventado se ignora en vez de romper")
    func unknownModifiersAreIgnored() {
        #expect(KeyCodes.flags(fromNames: ["hyper"]).isEmpty)
        #expect(KeyCodes.flags(fromNames: ["cmd", "hyper"]) == .maskCommand)
    }

    @Test("Un atajo se describe en orden fijo")
    func comboDescription() {
        let combo = KeyCombo(keyCode: KeyCodes.upArrow, flags: [.maskCommand, .maskControl])
        #expect(combo.described == "ctrl+cmd+↑")
        #expect(KeyCombo(keyCode: 999, flags: []).described == "key999")
    }

    @Test("Las flechas viajan con los bits de un teclado de verdad")
    func arrowsCarryDeviceFlags() {
        // Esto costó una sesión entera: un Ctrl+↑ fabricado sin `fn` y
        // `numericPad` llega al sistema y el WindowServer lo ignora sin decir nada.
        for flecha in [KeyCodes.upArrow, KeyCodes.downArrow, KeyCodes.leftArrow, KeyCodes.rightArrow] {
            let flags = ActionEmitter.deviceFlags(for: flecha)
            #expect(flags.contains(.maskSecondaryFn))
            #expect(flags.contains(.maskNumericPad))
            #expect(flags.contains(.maskNonCoalesced))
        }
    }

    @Test("Las demás teclas no llevan esos bits")
    func otherKeysDoNot() {
        let flags = ActionEmitter.deviceFlags(for: KeyCodes.f11)
        #expect(!flags.contains(.maskSecondaryFn))
        #expect(!flags.contains(.maskNumericPad))
        #expect(flags.contains(.maskNonCoalesced))
    }

    @Test("Los modificadores del atajo se suman a los del teclado")
    func flagsAreMerged() {
        let combo = KeyCombo(keyCode: KeyCodes.upArrow, flags: [.maskControl])
        let total = combo.flags.union(ActionEmitter.deviceFlags(for: combo.keyCode))
        #expect(total.contains(.maskControl))
        #expect(total.contains(.maskSecondaryFn))
    }
}

/// Pruebas del supresor de scroll: qué eventos se come mientras dura el gesto.
struct ScrollSuppressorTests {

    private static func suppressor(tailMs: Int, freezeCursor: Bool = false) -> ScrollSuppressor {
        var config = Config()
        config.suppressScrollTailMs = tailMs
        config.freezeCursorDuringGesture = freezeCursor
        let s = ScrollSuppressor()
        s.apply(config: config)
        return s
    }

    @Test("En reposo el scroll pasa")
    func idleLetsScrollThrough() {
        #expect(!Self.suppressor(tailMs: 250).shouldSuppress(isMovement: false))
    }

    @Test("Durante el gesto el scroll se come")
    func holdSuppressesScroll() {
        let s = Self.suppressor(tailMs: 250)
        s.holdSuppression()
        #expect(s.shouldSuppress(isMovement: false))
    }

    @Test("Soltar devuelve el scroll de inmediato")
    func releaseRestoresScroll() {
        let s = Self.suppressor(tailMs: 250)
        s.holdSuppression()
        s.release()
        #expect(!s.shouldSuppress(isMovement: false))
    }

    @Test("Con la cola en cero igual se suprime un instante")
    func minimumHoldApplies() {
        // Si no, poner la cola a 0 significaría "no suprimir nunca" y el scroll
        // se colaría entre frame y frame.
        let s = Self.suppressor(tailMs: 0)
        s.holdSuppression()
        #expect(s.shouldSuppress(isMovement: false))
    }

    @Test("El puntero se sigue moviendo salvo que se pida congelarlo")
    func movementPassesUnlessFrozen() {
        let normal = Self.suppressor(tailMs: 250)
        normal.holdSuppression()
        #expect(!normal.shouldSuppress(isMovement: true))
        #expect(!normal.wantsMovementEvents())

        let congelado = Self.suppressor(tailMs: 250, freezeCursor: true)
        congelado.holdSuppression()
        #expect(congelado.shouldSuppress(isMovement: true))
        #expect(congelado.wantsMovementEvents())
    }
}

/// Pruebas de cómo se describe un dispositivo conectado.
struct DeviceInfoTests {

    private static func device(builtIn: Bool, width: Int32, height: Int32) -> MultitouchBridge.DeviceInfo {
        MultitouchBridge.DeviceInfo(ref: UnsafeMutableRawPointer(bitPattern: 1)!, familyID: 112,
                                    isBuiltIn: builtIn, surfaceWidth: width, surfaceHeight: height)
    }

    @Test("Un Magic Mouse se reconoce por su sensor alargado")
    func recognizesMagicMouse() {
        // El sensor del mouse es más alto que ancho; el del trackpad, al revés.
        #expect(Self.device(builtIn: false, width: 5000, height: 11000).looksLikeMagicMouse)
        #expect(!Self.device(builtIn: false, width: 11000, height: 5000).looksLikeMagicMouse)
    }

    @Test("El trackpad del portátil no cuenta")
    func builtInIsNotAMouse() {
        #expect(!Self.device(builtIn: true, width: 5000, height: 11000).looksLikeMagicMouse)
    }

    @Test("Sin medidas no se adivina")
    func missingDimensions() {
        #expect(!Self.device(builtIn: false, width: 0, height: 0).looksLikeMagicMouse)
    }

    @Test("El tamaño se muestra en milímetros")
    func describedSize() {
        #expect(Self.device(builtIn: false, width: 5000, height: 11000).describedSize == "50.0 × 110.0 mm")
    }
}
