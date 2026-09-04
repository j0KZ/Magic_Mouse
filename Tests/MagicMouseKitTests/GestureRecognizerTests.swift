import XCTest
@testable import MagicMouseKit

/// What the recognizer does to real recordings from the user's Magic Mouse.
///
/// These are not unit tests of an abstraction — they are the only evidence this
/// project has that the gesture works at all, replayed. Every number here was
/// measured on the hardware, so a change that moves one is a change in
/// behaviour, not a test that needs updating.
final class GestureRecognizerTests: XCTestCase {

    // MARK: - Debe disparar

    func testFlicksRápidosDisparan() throws {
        let fired = Fixture.replay(try Fixture.frames("flick.jsonl"))

        // 12 flicks deliberados en la grabación. Que no baje: cada uno que se
        // pierda es un gesto que el usuario hizo y la app se comió.
        XCTAssertEqual(fired.count, 12, "flicks reconocidos: \(fired.map(\.direction))")

        // Hacia adelante sube y = Mission Control. Si esto se invierte, invertY
        // está mal y el gesto abre lo contrario de lo que se pidió.
        let ups = fired.filter { $0.direction == .up }
        XCTAssertEqual(ups.count, 8)
        XCTAssertTrue(fired.allSatisfy { $0.direction == .up || $0.direction == .down },
                      "un flick vertical no puede salir como horizontal")
    }

    // MARK: - No debe disparar

    func testUsoNormalNoDispara() throws {
        let fired = Fixture.replay(try Fixture.frames("ruido.jsonl"))
        XCTAssertTrue(fired.isEmpty,
                      "falso positivo con la mano apoyada: \(fired.map(\.direction))")
    }

    func testBarridoLentoNoDispara() throws {
        // El contraejemplo que obligó a la compuerta de velocidad: recorre la
        // misma distancia que un flick, en 2–7 s en vez de 0,2.
        let fired = Fixture.replay(try Fixture.frames("barrido-lento.jsonl"))
        XCTAssertTrue(fired.isEmpty,
                      "un barrido lento no es un gesto: \(fired.map(\.direction))")
    }

    func testBarridoLateralNoDispara() throws {
        // Límite físico del dispositivo, no de la configuración: tres dedos
        // ocupan el ancho de la superficie y no queda recorrido lateral.
        let fired = Fixture.replay(try Fixture.frames("lateral.jsonl"))
        XCTAssertTrue(fired.isEmpty)
    }

    // MARK: - Regresiones

    func testElTrazoCaducaCuandoElStreamSeCorta() throws {
        // El stream multitouch no manda un frame de cierre garantizado: si el
        // dispositivo se duerme o se cae del Bluetooth con la mano encima,
        // simplemente deja de llegar nada. Sin caducidad, ese `peakFingers` de 3
        // sigue en pie un minuto después, cuando dos dedos aterrizan para hacer
        // scroll — y el scroll dispara un gesto.
        let recognizer = GestureRecognizer(config: Config())
        for step in 0..<20 {
            let t = 3000 + Double(step) * 0.015
            let touches = (0..<3).map { i in
                Touch(id: Int32(30 + i), state: .touching,
                      x: 0.25 + Float(i) * 0.25, y: 0.4, vx: 0, vy: 0, size: 1)
            }
            _ = recognizer.handle(touches: touches, timestamp: t)
        }
        // Aquí se corta el stream. Nadie manda un frame de «ya no hay dedos».

        var fired: [Direction] = []
        for step in 0..<45 {
            let t = 3060 + Double(step) * 0.015
            let y = 0.05 + Float(step) * 0.02
            let touches = [
                Touch(id: 90, state: .touching, x: 0.35, y: y, vx: 0, vy: 0, size: 1),
                Touch(id: 91, state: .touching, x: 0.65, y: y, vx: 0, vy: 0, size: 1),
            ]
            if let r = recognizer.handle(touches: touches, timestamp: t) { fired.append(r.direction) }
        }
        XCTAssertTrue(fired.isEmpty, "dos dedos heredaron el trazo anterior: \(fired)")
    }

    func testLevantarLaManoCierraElTrazo() throws {
        // Misma trampa, camino distinto: tres dedos, se levantan, y antes de que
        // pase la gracia de dropout aterrizan dos a hacer scroll. La gracia es
        // para el dedo del borde que parpadea, no para esto.
        let recognizer = GestureRecognizer(config: Config())
        for step in 0..<20 {
            let t = 4000 + Double(step) * 0.015
            let touches = (0..<3).map { i in
                Touch(id: Int32(40 + i), state: .touching,
                      x: 0.25 + Float(i) * 0.25, y: 0.4, vx: 0, vy: 0, size: 1)
            }
            _ = recognizer.handle(touches: touches, timestamp: t)
        }
        // Un frame de despegue: contactos presentes, ninguno apoyado.
        _ = recognizer.handle(touches: (0..<3).map { i in
            Touch(id: Int32(40 + i), state: .leaving,
                  x: 0.25 + Float(i) * 0.25, y: 0.4, vx: 0, vy: 0, size: 0)
        }, timestamp: 4000.3)

        var fired: [Direction] = []
        for step in 0..<45 {
            let t = 4000.4 + Double(step) * 0.015
            let y = 0.05 + Float(step) * 0.02
            let touches = [
                Touch(id: 92, state: .touching, x: 0.35, y: y, vx: 0, vy: 0, size: 1),
                Touch(id: 93, state: .touching, x: 0.65, y: y, vx: 0, vy: 0, size: 1),
            ]
            if let r = recognizer.handle(touches: touches, timestamp: t) { fired.append(r.direction) }
        }
        XCTAssertTrue(fired.isEmpty, "el scroll heredó los 3 dedos anteriores: \(fired)")
    }

    func testUnSoloDisparoPorContacto() throws {
        // Tres dedos que cruzan la superficie de un tirón sin levantarse: un
        // gesto, no uno por frame mientras siga cumpliendo la compuerta.
        let recognizer = GestureRecognizer(config: Config())
        var fired: [Direction] = []
        // 0,02 por frame a 15 ms = 0,29 por ventana de 220 ms, por encima del
        // umbral de 0,24 durante todo el recorrido.
        for step in 0..<45 {
            let t = 1000 + Double(step) * 0.015
            let y = 0.05 + Float(step) * 0.02
            let touches = (0..<3).map { i in
                Touch(id: Int32(10 + i), state: .touching,
                      x: 0.25 + Float(i) * 0.25, y: y, vx: 0, vy: 0, size: 1)
            }
            if let r = recognizer.handle(touches: touches, timestamp: t) { fired.append(r.direction) }
        }
        XCTAssertEqual(fired, [.up], "un contacto continuo disparó \(fired.count) veces")
    }

    func testDosDedosNuncaDisparan() throws {
        // El scroll de siempre tiene que seguir siendo scroll.
        let recognizer = GestureRecognizer(config: Config())
        var fired = 0
        for step in 0..<60 {
            let t = 2000 + Double(step) * 0.015
            let y = 0.05 + Float(step) * 0.015
            let touches = (0..<2).map { i in
                Touch(id: Int32(20 + i), state: .touching,
                      x: 0.35 + Float(i) * 0.3, y: y, vx: 0, vy: 0, size: 1)
            }
            if recognizer.handle(touches: touches, timestamp: t) != nil { fired += 1 }
        }
        XCTAssertEqual(fired, 0)
    }
}
