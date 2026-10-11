import simd
import CoreGraphics

/// Malla de control cols×rows en coordenadas normalizadas de la vista (0...1, origen arriba-izquierda).
/// Puntos en orden row-major: índice = fila * cols + columna. UV de cada punto = (col/(cols-1), fila/(rows-1)).
/// Una malla 2×2 es un Quad Warp (perspectiva exacta); mayores densidades se subdividen y se interpolan.
struct Mesh: Codable {
    var cols: Int
    var rows: Int
    var points: [SIMD2<Float>]
    var smooth: Bool

    static let subdivisionsPerCell = 12

    /// Grilla uniforme centrada, ajustada a la proporción `aspect` (ancho/alto) del contenido.
    static func grid(cols: Int, rows: Int, viewSize: CGSize, smooth: Bool, aspect: Float = 1) -> Mesh {
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let width = min(0.6 * w, 0.6 * h * aspect), height = width / aspect
        let hx = width / 2 / w, hy = height / 2 / h
        var pts: [SIMD2<Float>] = []
        for j in 0..<rows {
            for i in 0..<cols {
                let u = Float(i) / Float(cols - 1), v = Float(j) / Float(rows - 1)
                pts.append([0.5 - hx + 2 * hx * u, 0.5 - hy + 2 * hy * v])
            }
        }
        return Mesh(cols: cols, rows: rows, points: pts, smooth: smooth)
    }

    // MARK: Interpolación

    /// Punto de control con extrapolación lineal fuera de rango (mantiene los bordes rectos).
    private func P(_ i: Int, _ j: Int) -> SIMD2<Float> {
        if i < 0 { return 2 * P(0, j) - P(1, j) }
        if i >= cols { return 2 * P(cols - 1, j) - P(cols - 2, j) }
        if j < 0 { return 2 * P(i, 0) - P(i, 1) }
        if j >= rows { return 2 * P(i, rows - 1) - P(i, rows - 2) }
        return points[j * cols + i]
    }

    private static func catmullRom(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>,
                                   _ p3: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
        let t2 = t * t, t3 = t2 * t
        let a = p1 * Float(2)
        let b = (p2 - p0) * t
        var c = p0 * Float(2)
        c -= p1 * Float(5)
        c += p2 * Float(4)
        c -= p3
        c *= t2
        var d = p1 * Float(3)
        d -= p0
        d -= p2 * Float(3)
        d += p3
        d *= t3
        return (a + b + c + d) * Float(0.5)
    }

    /// Posición en pantalla (normalizada) para un UV cualquiera de la superficie.
    func eval(u: Float, v: Float) -> SIMD2<Float> {
        let fu = u * Float(cols - 1), fv = v * Float(rows - 1)
        let i = min(max(Int(fu), 0), cols - 2), j = min(max(Int(fv), 0), rows - 2)
        let tu = fu - Float(i), tv = fv - Float(j)
        if !smooth {
            let a = P(i, j) + (P(i + 1, j) - P(i, j)) * tu
            let b = P(i, j + 1) + (P(i + 1, j + 1) - P(i, j + 1)) * tu
            return a + (b - a) * tv
        }
        var col: [SIMD2<Float>] = []
        for dj in -1...2 {
            col.append(Mesh.catmullRom(P(i - 1, j + dj), P(i, j + dj), P(i + 1, j + dj), P(i + 2, j + dj), tu))
        }
        return Mesh.catmullRom(col[0], col[1], col[2], col[3], tv)
    }

    /// Posición en pantalla (normalizada) de un UV tal como la dibuja el render: con perspectiva exacta en el caso 2×2.
    func screenPoint(u: Float, v: Float) -> SIMD2<Float> {
        guard cols == 2 && rows == 2 else { return eval(u: u, v: v) }
        // Los pesos están en el mismo espacio NDC que se usó para calcularlos; la fórmula es afín-invariante.
        let w = quadWeights
        let b: [Float] = [(1 - u) * (1 - v), u * (1 - v), (1 - u) * v, u * v]   // TL, TR, BL, BR
        var num = SIMD2<Float>(0, 0), den: Float = 0
        for i in 0..<4 { num += points[i] * (b[i] * w[i]); den += b[i] * w[i] }
        return num / den
    }

    /// Re-muestrea la superficie actual a otra densidad de nodos, conservando la forma.
    func resampled(cols nc: Int, rows nr: Int) -> Mesh {
        var pts: [SIMD2<Float>] = []
        for b in 0..<nr {
            for a in 0..<nc {
                pts.append(screenPoint(u: Float(a) / Float(nc - 1), v: Float(b) / Float(nr - 1)))
            }
        }
        return Mesh(cols: nc, rows: nr, points: pts, smooth: smooth)
    }

    // MARK: Geometría para render

    static func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> { [2 * p.x - 1, 1 - 2 * p.y] }

    /// Pesos de clip-w para un quad 2×2 (interpolación con perspectiva correcta).
    var quadWeights: [Float] {
        let p = points.map(Mesh.ndc)            // TL, TR, BL, BR
        let r = p[3] - p[0], v = p[2] - p[1]    // diagonales TL→BR y TR→BL
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        let denom = cross(r, v)
        guard abs(denom) > 1e-9 else { return [1, 1, 1, 1] }
        let d = p[1] - p[0]
        let t = cross(d, v) / denom, s = cross(d, r) / denom
        guard t > 0.001, t < 0.999, s > 0.001, s < 0.999 else { return [1, 1, 1, 1] }
        return [1 - t, 1 - s, s, t]             // TL, TR, BL, BR
    }

    struct Grid {
        var vertices: [Float] = []   // x, y (NDC), u, v, w
        var indices: [UInt32] = []
        var lines: [Float] = []      // pares de puntos NDC (isolíneas de los nodos de control)
    }

    func buildGrid() -> Grid {
        let isQuad = cols == 2 && rows == 2
        let s = isQuad ? 1 : Mesh.subdivisionsPerCell
        let gx = (cols - 1) * s, gy = (rows - 1) * s
        let weights = isQuad ? quadWeights : []

        var g = Grid()
        g.vertices.reserveCapacity((gx + 1) * (gy + 1) * 5)
        for b in 0...gy {
            for a in 0...gx {
                let u = Float(a) / Float(gx), v = Float(b) / Float(gy)
                let p = Mesh.ndc(eval(u: u, v: v))
                let w = isQuad ? weights[b * 2 + a] : 1
                g.vertices += [p.x, p.y, u, v, w]
            }
        }
        let stride = gx + 1
        for b in 0..<gy {
            for a in 0..<gx {
                let i0 = UInt32(b * stride + a), i1 = i0 + 1
                let i2 = UInt32((b + 1) * stride + a), i3 = i2 + 1
                g.indices += [i0, i1, i2, i1, i3, i2]
            }
        }
        func xy(_ a: Int, _ b: Int) -> [Float] {
            let k = (b * stride + a) * 5
            return [g.vertices[k], g.vertices[k + 1]]
        }
        for r in 0..<rows {
            for a in 0..<gx { g.lines += xy(a, r * s) + xy(a + 1, r * s) }
        }
        for c in 0..<cols {
            for b in 0..<gy { g.lines += xy(c * s, b) + xy(c * s, b + 1) }
        }
        return g
    }

    // MARK: Hit-testing

    /// Contorno (nodos del borde) en sentido horario.
    var outline: [SIMD2<Float>] {
        var o: [SIMD2<Float>] = []
        for i in 0..<cols { o.append(points[i]) }
        for j in 1..<rows { o.append(points[j * cols + cols - 1]) }
        if cols >= 2 { for i in stride(from: cols - 2, through: 0, by: -1) { o.append(points[(rows - 1) * cols + i]) } }
        if rows >= 3 { for j in stride(from: rows - 2, through: 1, by: -1) { o.append(points[j * cols]) } }
        return o
    }

    func contains(_ pt: SIMD2<Float>) -> Bool {
        let poly = outline
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > pt.y) != (b.y > pt.y),
               pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
