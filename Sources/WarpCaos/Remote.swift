import Foundation
import Network
import Combine
import QuartzCore

/// Efectos de luz controlados a distancia (destello, estroboscopio, brillo). Se escriben desde el hilo de red
/// y se leen desde el de dibujo, por eso van detrás de un candado.
final class Effects {
    static let shared = Effects()

    struct Snapshot {
        var gain: Float = 1
        var flash = SIMD3<Float>(1, 1, 1)
        var flashAmount: Float = 0
    }

    private let lock = NSLock()
    private var gain: Float = 1
    private var color = SIMD3<Float>(1, 1, 1)
    private var level: Float = 0
    private var triggeredAt = 0.0
    private var decay = 0.35        // segundos hasta apagarse casi del todo
    private var strobeHz = 0.0

    func flash(level: Float, color: SIMD3<Float>?) {
        lock.lock(); defer { lock.unlock() }
        self.level = min(max(level, 0), 1)
        if let color { self.color = color }
        triggeredAt = CACurrentMediaTime()
    }

    func setColor(_ c: SIMD3<Float>) { lock.lock(); color = c; lock.unlock() }
    func setDecay(_ seconds: Double) { lock.lock(); decay = min(max(seconds, 0.02), 5); lock.unlock() }
    func setStrobe(_ hz: Double) { lock.lock(); strobeHz = min(max(hz, 0), 30); lock.unlock() }
    func setGain(_ g: Float) { lock.lock(); gain = min(max(g, 0), 2); lock.unlock() }

    func reset() {
        lock.lock(); gain = 1; level = 0; strobeHz = 0; color = [1, 1, 1]; decay = 0.35; lock.unlock()
    }

    func current(_ now: Double) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var amt = level * Float(exp(-(now - triggeredAt) / (decay / 4)))
        if amt < 0.002 { amt = 0 }
        if strobeHz > 0 {
            let phase = (now * strobeHz).truncatingRemainder(dividingBy: 1)
            if phase < 0.3 { amt = 1 }
        }
        return Snapshot(gain: gain, flash: color, flashAmount: amt)
    }
}

/// Estado del sonido que llega de PulseCaos: niveles continuos y el instante del último golpe de cada banda.
/// Se escribe desde el hilo de red y se lee desde el de dibujo.
final class AudioReact {
    static let shared = AudioReact()

    private let lock = NSLock()
    private var levels: [ReactSource: Float] = [:]
    private var onsets: [ReactSource: Double] = [:]
    private var lastAudio = -100.0

    func setLevels(bass: Float, mid: Float, treble: Float, level: Float) {
        lock.lock(); defer { lock.unlock() }
        levels = [.bass: bass, .mid: mid, .treble: treble, .level: level]
        lastAudio = CACurrentMediaTime()
    }

    func onset(_ band: ReactSource) {
        lock.lock(); onsets[band] = CACurrentMediaTime(); lock.unlock()
    }

    /// Hay sonido llegando (o se disparó una prueba hace poco).
    func isLive(_ now: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now - lastAudio < 0.6
    }

    /// Valor continuo 0...1 de una banda (0 si PulseCaos dejó de mandar).
    func value(_ src: ReactSource, _ now: Double) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard now - lastAudio < 0.6 else { return 0 }
        switch src {
        case .beat: return levels[.bass] ?? 0
        default: return levels[src] ?? 0
        }
    }

    /// Intensidad 0...1 de un efecto disparado por golpes: salta a `strength` con cada golpe y decae sola.
    /// Con «Volumen» no hay golpes: sigue al nivel.
    func envelope(_ src: ReactSource, strength: Float, decay: Float, _ now: Double) -> Float {
        if src == .level { return strength * value(.level, now) }
        lock.lock(); defer { lock.unlock() }
        guard let t = onsets[src] else { return 0 }
        let e = strength * Float(exp(-(now - t) / Double(max(decay, 0.02) / 4)))
        return e < 0.002 ? 0 : e
    }
}

/// Recibe mensajes OSC por UDP (de PulseCaos, TouchOSC, Resolume, etc.) y los traduce a efectos.
///
///     /flash [nivel] [r g b]    destello (nivel 0–1; color opcional, 0–1)
///     /flash/color r g b        color del destello
///     /flash/decay segundos     cuánto tarda en apagarse
///     /strobe hz                estroboscopio (0 = apagado)
///     /brightness v             brillo general (1 = normal)
///     /blackout 0|1             salida en negro
///     /freeze 0|1               congelar la imagen
///     /reset                    vuelve efectos a sus valores normales
///     /audio graves medios agudos volumen   niveles del sonido (0–1), para las superficies con «Brillo» o «Volumen»
///     /onset/bass | /onset/mid | /onset/treble | /onset    golpe en esa banda (o en cualquiera): dispara destellos por superficie
final class OSCReceiver: ObservableObject {
    static let shared = OSCReceiver()
    static let defaultPort: UInt16 = 9000

    @Published private(set) var running = false
    @Published private(set) var port: UInt16 = OSCReceiver.defaultPort
    @Published private(set) var messageCount = 0
    @Published private(set) var lastMessage = ""
    @Published private(set) var failure: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "warpcaos.osc")
    private let log = ProcessInfo.processInfo.environment["WARPCAOS_LOG"] != nil

    func start(port: UInt16) {
        stop()
        self.port = port
        do {
            guard let p = NWEndpoint.Port(rawValue: port) else { return }
            let l = try NWListener(using: .udp, on: p)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.queue ?? .main)
                self?.receive(on: conn)
            }
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    switch st {
                    case .ready: self?.running = true; self?.failure = nil
                    case .failed(let e):
                        self?.running = false
                        self?.failure = "No se pudo escuchar en el puerto \(port): \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            failure = "No se pudo escuchar en el puerto \(port): \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty { self?.handle(packet: [UInt8](data)) }
            if error == nil { self?.receive(on: conn) } else { conn.cancel() }
        }
    }

    // MARK: - Formato OSC

    private enum Arg {
        case number(Double)
        case text(String)
        var float: Float? { if case .number(let d) = self { return Float(d) } else { return nil } }
    }

    private func handle(packet b: [UInt8]) {
        if b.starts(with: Array("#bundle".utf8)) {
            var i = 16   // "#bundle\0" + timetag
            while i + 4 <= b.count {
                let size = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
                i += 4
                guard size > 0, i + size <= b.count else { break }
                handle(packet: Array(b[i..<i + size]))
                i += size
            }
            return
        }
        guard let (address, args) = Self.parse(b) else { return }
        apply(address, args)
    }

    private static func readString(_ b: [UInt8], _ i: inout Int) -> String? {
        guard i < b.count, let end = b[i...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: b[i..<end], as: UTF8.self)
        i = (end / 4 + 1) * 4
        return s
    }

    private static func parse(_ b: [UInt8]) -> (String, [Arg])? {
        var i = 0
        guard let address = readString(b, &i), address.hasPrefix("/") else { return nil }
        guard let tags = readString(b, &i), tags.hasPrefix(",") else { return (address, []) }
        var args: [Arg] = []
        for t in tags.dropFirst() {
            switch t {
            case "f":
                guard i + 4 <= b.count else { return (address, args) }
                let bits = UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
                args.append(.number(Double(Float(bitPattern: bits)))); i += 4
            case "i":
                guard i + 4 <= b.count else { return (address, args) }
                let v = Int32(bitPattern: UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
                args.append(.number(Double(v))); i += 4
            case "d":
                guard i + 8 <= b.count else { return (address, args) }
                var bits: UInt64 = 0
                for k in 0..<8 { bits = bits << 8 | UInt64(b[i + k]) }
                args.append(.number(Double(bitPattern: bits))); i += 8
            case "s":
                guard let s = readString(b, &i) else { return (address, args) }
                args.append(.text(s))
            case "T": args.append(.number(1))
            case "F": args.append(.number(0))
            case "h", "t":
                i += 8
            default: break
            }
        }
        return (address, args)
    }

    // MARK: - Acciones

    private func apply(_ address: String, _ args: [Arg]) {
        let nums = args.compactMap { $0.float }
        let fx = Effects.shared
        var known = true
        switch address.lowercased() {
        case "/flash":
            let level = nums.first ?? 1
            let color: SIMD3<Float>? = nums.count >= 4 ? [nums[1], nums[2], nums[3]] : nil
            fx.flash(level: level, color: color)
        case "/flash/color":
            if nums.count >= 3 { fx.setColor([nums[0], nums[1], nums[2]]) }
        case "/flash/decay":
            if let v = nums.first { fx.setDecay(Double(v)) }
        case "/strobe":
            fx.setStrobe(Double(nums.first ?? 0))
        case "/brightness":
            if let v = nums.first { fx.setGain(v) }
        case "/blackout":
            let on = (nums.first ?? 1) > 0.5
            DispatchQueue.main.async { AppState.shared.blackout = on }
        case "/freeze":
            let on = (nums.first ?? 1) > 0.5
            DispatchQueue.main.async { AppState.shared.freeze = on }
        case "/audio":
            if nums.count >= 4 { AudioReact.shared.setLevels(bass: nums[0], mid: nums[1], treble: nums[2], level: nums[3]) }
        case "/onset/bass": AudioReact.shared.onset(.bass)
        case "/onset/mid": AudioReact.shared.onset(.mid)
        case "/onset/treble": AudioReact.shared.onset(.treble)
        case "/onset": AudioReact.shared.onset(.beat)
        case "/reset":
            fx.reset()
            DispatchQueue.main.async { AppState.shared.blackout = false; AppState.shared.freeze = false }
        default:
            known = false
        }
        let text = address + (nums.isEmpty ? "" : " " + nums.map { String(format: "%.2f", $0) }.joined(separator: " "))
        if log { print("osc: \(text)\(known ? "" : " (desconocido)")"); fflush(stdout) }
        if address.lowercased() == "/audio" { return }   // llega ~30 veces por segundo: no vale la pena mostrarlo
        DispatchQueue.main.async {
            self.messageCount += 1
            self.lastMessage = known ? text : text + " (desconocido)"
        }
    }
}
