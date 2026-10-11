import Foundation
import simd

enum Source: Equatable {
    case pattern(Pattern)
    case file(URL)

    var displayName: String {
        switch self {
        case .pattern(let p): return "Patrón: \(p.rawValue)"
        case .file(let url): return url.lastPathComponent
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

    /// Contorno en UV (0...1, y hacia abajo), con las aristas subdivididas para seguir la deformación de la malla.
    /// Debe coincidir con las SDF de `Shaders`.
    func outlineUV() -> [SIMD2<Float>] {
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
        // p → q (cuadrado normalizado) → UV.
        let uv: [SIMD2<Float>] = verts.map { p in
            let q = SIMD2<Float>(p.x / scale.x, (p.y - offsetY) / scale.y)
            return [q.x / 2 + 0.5, 0.5 - q.y / 2]
        }
        guard self != .ellipse else { return uv }
        var out: [SIMD2<Float>] = []
        for i in 0..<uv.count {
            let a = uv[i], b = uv[(i + 1) % uv.count]
            for k in 0..<16 { out.append(a + (b - a) * (Float(k) / 16)) }
        }
        return out
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

    /// Proporción objetivo del cuadrilátero al crearlo: las formas son cuadradas; el rectángulo sigue al contenido.
    var meshAspect: Float { shape == .rectangle ? contentAspect : 1 }

    // Solo se persiste lo que define el proyecto (no revision, spawnOffset, demoStyle ni isVideo).
    private enum CodingKeys: String, CodingKey {
        case id, name, source, cols, rows, smooth, mesh, visible, opacity, playing, muted
        case contentAspect, meshEdited, masks, shape, shapeFeather, fit
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
    }
}
