import Foundation
import Testing
@testable import MagicMouseKit

/// El ajuste del reconocedor contra las cinco grabaciones reales.
///
/// Los tests que ya existían comprueban que el ajuste de fábrica acierta. Estos
/// comprueban **por qué** es ese y no otro: son los números que CLAUDE.md da por
/// medidos, y hasta ahora vivían solo en la documentación. Si alguien mueve la
/// ventana o el umbral «porque parece razonable», aquí se ve lo que rompe.
struct AjusteTests {

    private static func disparos(_ archivo: String, ventana: Int? = nil,
                                 umbral: Float? = nil, dominancia: Float? = nil) throws -> Int {
        var config = Config()
        if let ventana { config.swipeWindowMs = ventana }
        if let umbral { config.swipeThreshold = umbral }
        if let dominancia { config.axisDominance = dominancia }
        return Fixture.replay(try Fixture.frames(archivo), config: config).count
    }

    @Test("El ajuste de fábrica separa los flicks del uso normal")
    func ajusteDeFabrica() throws {
        // Flicks: se reconocen. Uso normal, barrido lento y movimiento lateral:
        // ni uno. Esa es toda la razón de ser del ajuste.
        #expect(try Self.disparos("flick.jsonl") == 11)
        #expect(try Self.disparos("flick-natural.jsonl") == 8)
        #expect(try Self.disparos("ruido.jsonl") == 0)
        #expect(try Self.disparos("barrido-lento.jsonl") == 0)
        #expect(try Self.disparos("lateral.jsonl") == 0)
    }

    @Test("Una ventana larga llena la app de falsos positivos")
    func ventanaLarga() throws {
        // Va contra la intuición: con más tiempo para acumular movimiento, la
        // deriva de la mano apoyada recorre tanto como un flick. Con 220 ms el
        // uso normal empieza a disparar Mission Control solo.
        #expect(try Self.disparos("ruido.jsonl", ventana: 220) > 0)
        #expect(try Self.disparos("barrido-lento.jsonl", ventana: 220) > 0)
        #expect(try Self.disparos("lateral.jsonl", ventana: 220) > 0)
    }

    @Test("Un umbral alto deja de reconocer los flicks de verdad")
    func umbralAlto() throws {
        // 0,24 es lo que sugería calibrar con flicks hechos a propósito: con los
        // flicks de alguien usando la app de verdad, no reconoce ninguno.
        #expect(try Self.disparos("flick-natural.jsonl", umbral: 0.24) == 0)
    }

    @Test("Un umbral bajo vuelve a colar el uso normal")
    func umbralBajo() throws {
        #expect(try Self.disparos("ruido.jsonl", umbral: 0.03) > 0)
    }

    @Test("Sin exigir dominancia de eje, el movimiento lateral pasa por gesto")
    func sinDominancia() throws {
        // Es lo que ocurría con el valor sin tope: cualquier diagonal contaba.
        let conDominancia = try Self.disparos("lateral.jsonl", ventana: 220, dominancia: 1.6)
        let sinDominancia = try Self.disparos("lateral.jsonl", ventana: 220, dominancia: 1)
        #expect(sinDominancia >= conDominancia)
    }

    @Test("En este mouse los flicks son verticales")
    func soloVertical() throws {
        // Izquierda y derecha no se asignan a propósito: tres dedos ocupan casi
        // todo el ancho del sensor y un barrido lateral mueve menos que el ruido.
        let direcciones = Fixture.replay(try Fixture.frames("flick-natural.jsonl")).map(\.direction)
        #expect(!direcciones.isEmpty)
        #expect(direcciones.allSatisfy { $0 == .up || $0 == .down })
    }
}

/// Las grabaciones: se escriben, se releen y alimentan al reconocedor. Es el
/// formato del que dependen todos los tests de ajuste.
struct FrameLogTests {

    private static func tempFile() -> String {
        NSTemporaryDirectory() + "framelog-test-\(UUID().uuidString).jsonl"
    }

    @Test("Lo grabado se vuelve a leer igual")
    func roundTrip() throws {
        let path = Self.tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let recorder = try FrameLog.Recorder(path: path)
        recorder.write(timestamp: 1.0, touches: [Touch(id: 1, state: .touching, x: 0.5, y: 0.5,
                                                       vx: 0, vy: 0, size: 0.3)])
        recorder.write(timestamp: 1.5, touches: [])
        recorder.close()

        let frames = try FrameLog.read(path: path)
        #expect(frames.count == 2)
        #expect(frames[0].t == 1.0)
        #expect(frames[0].touches.first?.id == 1)
        #expect(frames[0].touches.first?.state == .touching)
        #expect(frames[1].touches.isEmpty)
    }

    @Test("Las posiciones se conservan")
    func positionsSurvive() throws {
        let path = Self.tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let recorder = try FrameLog.Recorder(path: path)
        recorder.write(timestamp: 2.0, touches: [Touch(id: 3, state: .making, x: 0.25, y: 0.75,
                                                       vx: 9, vy: 9, size: 0.9)])
        recorder.close()

        let touch = try #require(FrameLog.read(path: path).first?.touches.first)
        #expect(touch.x == 0.25)
        #expect(touch.y == 0.75)
        // La velocidad y el tamaño no se graban: el reconocedor los recalcula.
        #expect(touch.vx == 0)
    }

    @Test("Una línea corrupta no se lleva por delante la grabación")
    func corruptLinesAreSkipped() throws {
        let path = Self.tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let bueno = #"{"t":1.0,"c":[]}"#
        try (bueno + "\n{esto no es json}\n" + bueno + "\n").write(toFile: path,
                                                                   atomically: true, encoding: .utf8)
        #expect(try FrameLog.read(path: path).count == 2)
    }

    @Test("Las grabaciones versionadas siguen leyéndose")
    func fixturesStillLoad() throws {
        // Sin un Magic Mouse delante no se pueden volver a producir: son lo único
        // que convierte "el reconocedor parece razonable" en una medida.
        for archivo in ["flick.jsonl", "flick-natural.jsonl", "ruido.jsonl",
                        "barrido-lento.jsonl", "lateral.jsonl"] {
            #expect(try Fixture.frames(archivo).count > 100)
        }
    }
}
