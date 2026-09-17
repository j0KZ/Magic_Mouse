import Foundation
import Testing
@testable import MagicMouseKit

/// Pruebas de la configuración: lo que se guarda en `~/.config`, lo que se lee y
/// lo que se descarta por venir fuera de rango.
struct ConfigTests {

    private static func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test("Una configuración a medio escribir arranca igual")
    func partialConfigStillLoads() {
        // Todas las claves son opcionales a propósito: un archivo truncado no
        // debe dejar la app sin arrancar.
        let config = try? Self.decode(#"{"fingers": 3}"#)
        #expect(config?.fingers == 3)
        #expect(config?.swipeThreshold == Config().swipeThreshold)
        #expect(config?.enabled == Config().enabled)
    }

    @Test("Un archivo vacío da la configuración de fábrica")
    func emptyConfig() throws {
        let config = try Self.decode("{}")
        #expect(config.fingers == Config().fingers)
        #expect(config.language == Config().language)
        #expect(config.deviceSelection == Config().deviceSelection)
    }

    @Test("El número de dedos se acota a lo que tiene una mano")
    func fingersAreClamped() throws {
        #expect(try Self.decode(#"{"fingers": 99}"#).fingers == 5)
        #expect(try Self.decode(#"{"fingers": 0}"#).fingers == 1)
        #expect(try Self.decode(#"{"fingers": -5}"#).fingers == 1)
    }

    @Test("El umbral y la ventana del gesto se acotan")
    func thresholdsAreClamped() throws {
        #expect(try Self.decode(#"{"swipeThreshold": 5}"#).swipeThreshold == 0.9)
        #expect(try Self.decode(#"{"swipeThreshold": 0}"#).swipeThreshold == 0.01)
        #expect(try Self.decode(#"{"swipeWindowMs": 5}"#).swipeWindowMs == 60)
        #expect(try Self.decode(#"{"swipeWindowMs": 5000}"#).swipeWindowMs == 600)
    }

    @Test("Las esperas en milisegundos se acotan")
    func delaysAreClamped() throws {
        #expect(try Self.decode(#"{"dropoutGraceMs": 9999}"#).dropoutGraceMs == 1000)
        #expect(try Self.decode(#"{"returnLockoutMs": -1}"#).returnLockoutMs == 0)
        #expect(try Self.decode(#"{"suppressScrollTailMs": 99999}"#).suppressScrollTailMs == 2000)
    }

    @Test("La dominancia de eje también se acota")
    func axisDominanceIsClamped() throws {
        // Era el único número sin tope: con 0 o negativo cualquier diagonal
        // pasaba por gesto, y con un valor enorme no disparaba nunca.
        #expect(try Self.decode(#"{"axisDominance": 0}"#).axisDominance == 1)
        #expect(try Self.decode(#"{"axisDominance": -3}"#).axisDominance == 1)
        #expect(try Self.decode(#"{"axisDominance": 50}"#).axisDominance == 4)
        #expect(try Self.decode(#"{"axisDominance": 1.6}"#).axisDominance == 1.6)
    }

    @Test("Un idioma desconocido vuelve a automático")
    func unknownLanguage() throws {
        #expect(try Self.decode(#"{"language": "fr"}"#).language == "auto")
        #expect(try Self.decode(#"{"language": "es"}"#).language == "es")
    }

    @Test("Una selección de dispositivo desconocida conserva la de fábrica")
    func unknownDeviceSelection() throws {
        #expect(try Self.decode(#"{"deviceSelection": "loquesea"}"#).deviceSelection == Config().deviceSelection)
        #expect(try Self.decode(#"{"deviceSelection": "external"}"#).deviceSelection == .external)
    }

    @Test("Guardar y volver a leer no cambia nada")
    func roundTrip() throws {
        var config = Config()
        config.fingers = 4
        config.swipeThreshold = 0.07
        config.invertY = true
        config.bindings["up"] = "missionControl"

        let vuelta = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(vuelta.fingers == 4)
        #expect(vuelta.swipeThreshold == 0.07)
        #expect(vuelta.invertY)
        #expect(vuelta.action(for: .up) == .missionControl)
    }

    @Test("Una acción mal escrita no hace nada, en vez de hacer otra cosa")
    func unknownBindingDoesNothing() {
        var config = Config()
        config.bindings["up"] = "launchPadMalEscrito"
        #expect(config.action(for: .up) == Action.none)
    }

    @Test("Una dirección sin asignar no hace nada")
    func unboundDirection() {
        var config = Config()
        config.bindings.removeValue(forKey: "left")
        #expect(config.action(for: .left) == Action.none)
    }

    @Test("Cada dirección tiene su contraria")
    func opposites() {
        #expect(Direction.up.opposite == .down)
        #expect(Direction.down.opposite == .up)
        #expect(Direction.left.opposite == .right)
        #expect(Direction.right.opposite == .left)
    }

    @Test("Todas las direcciones y acciones tienen nombre traducible")
    func localizedNames() {
        // Cierra el círculo con la prueba que comprueba que esas claves existen
        // en los .strings: aquí se verifica que el código pide esas mismas.
        for d in Direction.allCases { #expect(d.localizedName == "direction.\(d.rawValue)") }
        for a in Action.allCases { #expect(a.localizedName == "action.\(a.rawValue)") }
    }
}
