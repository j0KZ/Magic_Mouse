import XCTest
@testable import MagicMouseKit

/// The two `.strings` files, checked against each other.
///
/// A key added to one language and forgotten in the other doesn't crash and
/// doesn't warn — it just shows `menu.sensitivity` in a menu, in front of
/// whoever happens to use that language. Which is never the person who added it.
final class LocalizationTests: XCTestCase {

    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)

    private func keys(_ language: String) throws -> [String: String] {
        let url = Self.directory
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: String], "\(language) no es una lista de propiedades")
    }

    func testLosDosIdiomasTienenLasMismasClaves() throws {
        let en = try keys("en")
        let es = try keys("es")

        let faltanEnEspanol = Set(en.keys).subtracting(es.keys).sorted()
        let faltanEnIngles = Set(es.keys).subtracting(en.keys).sorted()

        XCTAssertTrue(faltanEnEspanol.isEmpty, "sin traducir al español: \(faltanEnEspanol)")
        XCTAssertTrue(faltanEnIngles.isEmpty, "sin traducir al inglés: \(faltanEnIngles)")
    }

    func testNingunaTraduccionEstaVacia() throws {
        for language in ["en", "es"] {
            for (key, value) in try keys(language) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(language): «\(key)» está vacía")
            }
        }
    }

    func testLosMarcadoresDeFormatoCoinciden() throws {
        // "%d dedos" traducido como "%@ fingers" no falla al compilar: falla al
        // ejecutarse, leyendo un entero como puntero.
        let en = try keys("en")
        let es = try keys("es")

        func placeholders(_ text: String) -> [String] {
            let pattern = try! NSRegularExpression(pattern: "%[0-9.]*[@dfs]")
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }

        for (key, inglés) in en {
            guard let español = es[key] else { continue }
            XCTAssertEqual(placeholders(inglés), placeholders(español),
                           "los marcadores de «\(key)» no coinciden")
        }
    }

    func testCadaDireccionYAccionTienenNombre() throws {
        let en = try keys("en")
        for direction in Direction.allCases {
            XCTAssertNotNil(en["direction.\(direction.rawValue)"],
                            "falta el nombre de la dirección \(direction.rawValue)")
        }
        for action in Action.allCases {
            XCTAssertNotNil(en["action.\(action.rawValue)"],
                            "falta el nombre de la acción \(action.rawValue)")
        }
    }
}
