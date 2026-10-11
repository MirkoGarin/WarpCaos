import Foundation
import simd

enum Source: Equatable {
    case pattern(Pattern)
    case file(URL)
    /// Video (mp4, mov, HLS…) o imagen alojados en la red, reproducidos o descargados sin guardarlos como archivo.
    case url(URL)

    var displayName: String {
        switch self {
        case .pattern(let p): return "Patrón: \(p.rawValue)"
        case .file(let url): return url.lastPathComponent
        case .url(let url):
            let name = url.lastPathComponent
            return "URL: \(url.host ?? "")" + (name.isEmpty || name == "/" ? "" : "/…/\(name)")
        }
    }
}

private var revisionCounter = 0
func nextRevision() -> Int { revisionCounter &+= 1; return revisionCounter }

/// Máscara poligonal en espacio de pantalla (coordenadas normalizadas de la vista), aplicada a una superficie.
struct Mask: Identifiable, Codable {
    let id: UUID
    var name: String
    var points: [SIMD2<Float>]
    /// Ancho de la transición del borde, en puntos de vista.
    var feather: Float = 0
    var inverted = false
    /// false = "Mostrar" (el contenido solo se ve dentro); true = "Ocultar" (se recorta lo de adentro).
    var hides = false

    static let maxPoints = 64
}

/// Forma de la superficie. Se define en el espacio del contenido (UV), dentro del cuadrilátero de 4 esquinas,
/// así que sigue la perspectiva y la deformación de la malla.
enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle = "Rectángulo"
    case ellipse = "Círculo / elipse"
    case triangle = "Triángulo"
    case diamond = "Rombo"
    case pentagon = "Pentágono"
    case hexagon = "Hexágono"
    case octagon = "Octágono"
    case star = "Estrella"

    var id: String { rawValue }

    /// Identificador que entiende el shader (0 = sin recorte).
    var shaderID: UInt32 {
        switch self {
        case .rectangle: return 0
        case .ellipse: return 1
        case .triangle: return 2
        case .diamond: return 3
        case .pentagon: return 4
        case .hexagon: return 5
        case .octagon: return 6
        case .star: return 7
        }
    }

    /// Contorno en el cuadrado normalizado q (−1...1, y hacia arriba), ya rotado y volteado, con las aristas
    /// subdivididas para seguir la deformación de la malla. Debe coincidir con las SDF de `Shaders`.
    func qOutline(angle: Float = 0, flipH: Bool = false, flipV: Bool = false) -> [SIMD2<Float>] {
        // Espacio de forma `p` (vértice hacia arriba) y su ajuste al cuadrado [-1,1]².
        func poly(_ n: Int) -> [SIMD2<Float>] {
            (0..<n).map { k in
                let a = Float.pi / 2 + 2 * Float.pi * Float(k) / Float(n)
                return [cos(a), sin(a)]
            }
        }
        var verts: [SIMD2<Float>]
        var scale = SIMD2<Float>(1, 1), offsetY: Float = 0
        switch self {
        case .rectangle: verts = [[-1, 1], [1, 1], [1, -1], [-1, -1]]
        case .ellipse: verts = (0..<96).map { k in let a = 2 * Float.pi * Float(k) / 96; return [cos(a), sin(a)] }
        case .triangle: verts = poly(3); scale = [0.866, 0.75]; offsetY = 0.25
        case .diamond: verts = poly(4)
        case .pentagon: verts = poly(5); scale = [0.951, 0.9045]; offsetY = 0.0955
        case .hexagon: verts = poly(6); scale = [0.866, 1]
        case .octagon: verts = poly(8)
        case .star:
            verts = (0..<10).map { k in
                let a = Float.pi / 2 + Float.pi * Float(k) / 5
                let r: Float = k % 2 == 0 ? 1 : 0.5
                return [r * cos(a), r * sin(a)]
            }
            scale = [0.951, 0.9045]; offsetY = 0.0955
        }
        // p → q' (cuadrado normalizado) → q (aplicando la inversa de la transformación del shader, q' = R(θ)·F·q).
        let th = angle * .pi / 180, c = cos(th), s = sin(th)
        let qs: [SIMD2<Float>] = verts.map { p in
            let qp = SIMD2<Float>(p.x / scale.x, (p.y - offsetY) / scale.y)
            var q = SIMD2<Float>(c * qp.x + s * qp.y, -s * qp.x + c * qp.y)   // R(-θ)
            if flipH { q.x = -q.x }
            if flipV { q.y = -q.y }
            return q
        }
        guard self != .ellipse else { return qs }
        var out: [SIMD2<Float>] = []
        for i in 0..<qs.count {
            let a = qs[i], b = qs[(i + 1) % qs.count]
            for k in 0..<16 { out.append(a + (b - a) * (Float(k) / 16)) }
        }
        return out
    }

    /// Factor (≥ 1) por el que se achica la forma para que, rotada o volteada, siga cabiendo en el cuadrilátero.
    func fitScale(angle: Float, flipH: Bool, flipV: Bool) -> Float {
        guard self != .rectangle else { return 1 }
        let e = qOutline(angle: angle, flipH: flipH, flipV: flipV).map { max(abs($0.x), abs($0.y)) }.max() ?? 1
        return e > 1.0005 ? e : 1
    }

    /// Contorno en UV (0...1, y hacia abajo), ajustado al cuadrilátero.
    func outlineUV(angle: Float = 0, flipH: Bool = false, flipV: Bool = false) -> [SIMD2<Float>] {
        let e = fitScale(angle: angle, flipH: flipH, flipV: flipV)
        return qOutline(angle: angle, flipH: flipH, flipV: flipV).map { [$0.x / e / 2 + 0.5, 0.5 - $0.y / e / 2] }
    }
}

/// Cómo se acomoda el contenido dentro de la superficie.
enum FitMode: String, Codable {
    case stretch = "Estirar"   // el contenido ocupa todo el cuadrilátero (puede deformarse)
    case cover = "Cubrir"      // conserva la proporción y recorta lo que sobra
}

/// Una superficie de proyección: contenido + malla de warp + propiedades de capa.
struct SurfaceModel: Identifiable, Codable {
    var id: UUID
    var name: String
    var source: Source = .pattern(.checkerboard)

    // Configuración de la malla (fuente de verdad para crearla cuando `mesh` es nil).
    var cols = 4
    var rows = 4
    var smooth = true
    var mesh: Mesh? { didSet { revision = nextRevision() } }
    /// Cambia con cada modificación de la malla; el renderer reconstruye buffers al detectarlo.
    var revision = nextRevision()
    var spawnOffset = SIMD2<Float>(0, 0)
    var demoStyle: String?

    var visible = true
    var opacity: Float = 1
    var playing = true
    var muted = true

    // Información del contenido cargado (la reporta el renderer).
    var isVideo = false
    var contentAspect: Float = 1
    var meshEdited = false

    var masks: [Mask] = []

    var shape: ShapeKind = .rectangle
    /// Suavizado del borde de la forma (en unidades del cuadrado normalizado, 0...0.5).
    var shapeFeather: Float = 0
    var fit: FitMode = .stretch

    /// Rotación (grados, sentido horario) y volteo del contenido dentro de la superficie.
    var contentRotation: Float = 0
    var contentFlipH = false
    var contentFlipV = false
    /// Rotación y volteo de la forma dentro del cuadrilátero.
    var shapeRotation: Float = 0
    var shapeFlipH = false
    var shapeFlipV = false

    /// Matriz 2×2 (columnas) que lleva el UV centrado de la superficie al UV centrado de la textura:
    /// t = M·(uv − 0.5) + 0.5. Combina volteo, rotación y el ajuste Estirar/Cubrir.
    var contentMatrix: (SIMD2<Float>, SIMD2<Float>) {
        let th = contentRotation * .pi / 180, c = cos(th), s = sin(th)
        // Rotación horaria por -θ en coordenadas con y hacia abajo.
        let rinv = simd_float2x2(columns: (SIMD2<Float>(c, -s), SIMD2<Float>(s, c)))
        let flip = simd_float2x2(diagonal: SIMD2<Float>(contentFlipH ? -1 : 1, contentFlipV ? -1 : 1))
        if fit == .stretch {
            let m = rinv * flip
            return (m.columns.0, m.columns.1)
        }
        // Cubrir: el contenido (alto H, ancho ca·H) debe cubrir el cuadrilátero (sa × 1) ya rotado.
        let sa = meshAspect, ca = max(contentAspect, 0.001)
        var h: Float = 0
        for corner in [SIMD2<Float>(sa / 2, 0.5), SIMD2<Float>(sa / 2, -0.5)] {
            let r = rinv * corner
            h = max(h, 2 * abs(r.x) / ca, 2 * abs(r.y))
        }
        h = max(h, 0.001)
        let size = simd_float2x2(diagonal: SIMD2<Float>(1 / (ca * h), 1 / h))
        let phys = simd_float2x2(diagonal: SIMD2<Float>(sa, 1))
        let m = size * rinv * phys * flip
        return (m.columns.0, m.columns.1)
    }

    /// Matriz 2×2 (columnas) aplicada al cuadrado normalizado q (y hacia arriba) antes de evaluar la forma:
    /// q' = R(θ)·F·q.
    var shapeMatrix: (SIMD2<Float>, SIMD2<Float>) {
        let th = shapeRotation * .pi / 180, c = cos(th), s = sin(th)
        let r = simd_float2x2(columns: (SIMD2<Float>(c, s), SIMD2<Float>(-s, c)))
        let flip = simd_float2x2(diagonal: SIMD2<Float>(shapeFlipH ? -1 : 1, shapeFlipV ? -1 : 1))
        // Achicar la forma = agrandar q' (la forma se evalúa en q' = e·R·F·q).
        let e = shape.fitScale(angle: shapeRotation, flipH: shapeFlipH, flipV: shapeFlipV)
        let m = r * flip * e
        return (m.columns.0, m.columns.1)
    }

    /// Proporción objetivo del cuadrilátero al crearlo: las formas son cuadradas; el rectángulo sigue al contenido.
    var meshAspect: Float { shape == .rectangle ? contentAspect : 1 }

    // Solo se persiste lo que define el proyecto (no revision, spawnOffset, demoStyle ni isVideo).
    private enum CodingKeys: String, CodingKey {
        case id, name, source, cols, rows, smooth, mesh, visible, opacity, playing, muted
        case contentAspect, meshEdited, masks, shape, shapeFeather, fit
        case contentRotation, contentFlipH, contentFlipV, shapeRotation, shapeFlipH, shapeFlipV
    }
}

/// Decodificación tolerante: los proyectos guardados antes de que existieran las formas siguen abriendo.
extension SurfaceModel {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name))
        source = try c.decode(Source.self, forKey: .source)
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 4
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 4
        smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth) ?? true
        mesh = try c.decodeIfPresent(Mesh.self, forKey: .mesh)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        playing = try c.decodeIfPresent(Bool.self, forKey: .playing) ?? true
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        contentAspect = try c.decodeIfPresent(Float.self, forKey: .contentAspect) ?? 1
        meshEdited = try c.decodeIfPresent(Bool.self, forKey: .meshEdited) ?? false
        masks = try c.decodeIfPresent([Mask].self, forKey: .masks) ?? []
        shape = try c.decodeIfPresent(ShapeKind.self, forKey: .shape) ?? .rectangle
        shapeFeather = try c.decodeIfPresent(Float.self, forKey: .shapeFeather) ?? 0
        fit = try c.decodeIfPresent(FitMode.self, forKey: .fit) ?? .stretch
        contentRotation = try c.decodeIfPresent(Float.self, forKey: .contentRotation) ?? 0
        contentFlipH = try c.decodeIfPresent(Bool.self, forKey: .contentFlipH) ?? false
        contentFlipV = try c.decodeIfPresent(Bool.self, forKey: .contentFlipV) ?? false
        shapeRotation = try c.decodeIfPresent(Float.self, forKey: .shapeRotation) ?? 0
        shapeFlipH = try c.decodeIfPresent(Bool.self, forKey: .shapeFlipH) ?? false
        shapeFlipV = try c.decodeIfPresent(Bool.self, forKey: .shapeFlipV) ?? false
    }
}
