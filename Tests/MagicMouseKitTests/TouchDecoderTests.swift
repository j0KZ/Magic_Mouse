import Foundation
import Testing
@testable import MagicMouseKit

/// El contrato con el framework privado de multitáctil: dónde está cada campo
/// dentro de los 96 bytes que entrega cada contacto.
///
/// Los fixtures no cubren esto, porque están grabados ya decodificados. Si Apple
/// mueve un campo en una versión de macOS, esto es lo único que lo delata: el
/// resto de la app seguiría compilando y el gesto simplemente dejaría de salir.
struct TouchDecoderTests {

    /// Arma el buffer que entregaría el sistema, escribiendo cada campo en su
    /// offset. Los offsets se repiten aquí a propósito: si alguien cambia los del
    /// código sin querer, esta prueba deja de casar.
    private static func buffer(_ contacts: [(id: Int32, state: Int32, x: Float, y: Float,
                                             vx: Float, vy: Float, size: Float)]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: max(1, contacts.count) * TouchDecoder.stride)
        for (i, c) in contacts.enumerated() {
            let base = i * TouchDecoder.stride
            func put<T>(_ value: T, at offset: Int) {
                withUnsafeBytes(of: value) { raw in
                    for (k, byte) in raw.enumerated() { bytes[base + offset + k] = byte }
                }
            }
            put(c.id, at: 16)
            put(c.state, at: 20)
            put(c.x, at: 32)
            put(c.y, at: 36)
            put(c.vx, at: 40)
            put(c.vy, at: 44)
            put(c.size, at: 48)
        }
        return bytes
    }

    private static func decode(_ bytes: [UInt8], count: Int32) -> [Touch] {
        bytes.withUnsafeBytes { raw in
            TouchDecoder.decode(raw.baseAddress!, count: count)
        }
    }

    @Test("Cada campo se lee de su sitio")
    func decodesEveryField() {
        let bytes = Self.buffer([(id: 7, state: 4, x: 0.25, y: 0.75, vx: -1.5, vy: 2.5, size: 0.4)])
        let touch = Self.decode(bytes, count: 1).first

        #expect(touch?.id == 7)
        #expect(touch?.state == .touching)
        #expect(touch?.x == 0.25)
        #expect(touch?.y == 0.75)
        #expect(touch?.vx == -1.5)
        #expect(touch?.vy == 2.5)
        #expect(touch?.size == 0.4)
    }

    @Test("Los contactos van uno tras otro cada 96 bytes")
    func decodesSeveralContacts() {
        let bytes = Self.buffer([
            (id: 1, state: 4, x: 0.1, y: 0.1, vx: 0, vy: 0, size: 0.3),
            (id: 2, state: 4, x: 0.2, y: 0.2, vx: 0, vy: 0, size: 0.3),
            (id: 3, state: 3, x: 0.3, y: 0.3, vx: 0, vy: 0, size: 0.3)
        ])
        let touches = Self.decode(bytes, count: 3)
        #expect(touches.map(\.id) == [1, 2, 3])
        #expect(touches.map(\.x) == [0.1, 0.2, 0.3])
        #expect(touches[2].state == .making)
    }

    @Test("Un estado desconocido no rompe la lectura")
    func unknownStateFallsBack() {
        // El framework es privado: un estado nuevo en otra versión de macOS no
        // debe hacer que la app deje de leer el resto del contacto.
        let bytes = Self.buffer([(id: 1, state: 99, x: 0.5, y: 0.5, vx: 0, vy: 0, size: 0.3)])
        let touch = Self.decode(bytes, count: 1).first
        #expect(touch?.state == .notTouching)
        #expect(touch?.x == 0.5)
    }

    @Test("Sin contactos no se lee nada")
    func emptyFrame() {
        let bytes = Self.buffer([])
        #expect(Self.decode(bytes, count: 0).isEmpty)
        #expect(Self.decode(bytes, count: -3).isEmpty)
    }

    @Test("Un número de contactos absurdo no sale del buffer")
    func countIsCapped() {
        // El conteo viene de un callback privado: sin el tope, un valor basura
        // leería memoria fuera del buffer.
        var contactos: [(id: Int32, state: Int32, x: Float, y: Float, vx: Float, vy: Float, size: Float)] = []
        for i in 0..<TouchDecoder.maxTouches {
            contactos.append((id: Int32(i), state: 4, x: 0, y: 0, vx: 0, vy: 0, size: 0.3))
        }
        let bytes = Self.buffer(contactos)
        #expect(Self.decode(bytes, count: 9_999).count == TouchDecoder.maxTouches)
    }

    @Test("Solo los dedos apoyados cuentan")
    func onlyContactsDown() {
        // Un dedo rozando (hovering) o levantándose (leaving) no es un dedo apoyado:
        // de eso depende que un gesto de tres dedos se cuente como tal.
        #expect(Touch.State.touching.isDown)
        #expect(Touch.State.making.isDown)
        #expect(!Touch.State.hovering.isDown)
        #expect(!Touch.State.leaving.isDown)
        #expect(!Touch.State.notTouching.isDown)
    }
}
