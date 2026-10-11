import SwiftUI
import simd
import Combine
import UniformTypeIdentifiers

/// Estado compartido entre la UI SwiftUI, la vista de edición y el renderer.
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var surfaces: [SurfaceModel] = []
    @Published var selectedID: UUID?
    /// Máscara en edición (de la superficie activa). Con una máscara elegida, el canvas edita sus vértices.
    @Published var selectedMaskID: UUID?
    @Published var showOverlay = true
    @Published var status: String?
    /// Proporción (ancho/alto) del lienzo; coincide con la pantalla de salida para que lo editado sea lo proyectado.
    @Published var canvasAspect: Float = 16.0 / 9.0
    @Published var outputActive = false
    @Published var blackout = false
    @Published var freeze = false
    @Published var projectURL: URL?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Nodos seleccionados de la superficie activa.
    var selection = Set<Int>()
    var marquee: (SIMD2<Float>, SIMD2<Float>)?
    var viewSize = CGSize(width: 1000, height: 430)

    var surfaceCounter = 0
    weak var renderer: Renderer?
    var output: OutputController?
    var autosaveCancellable: AnyCancellable?
    /// Mientras hay salida activa se impide que la pantalla se apague o la app entre en App Nap.
    var activity: NSObjectProtocol?

    /// Margen (en puntos) alrededor del lienzo en el editor, para alcanzar nodos que se salen del borde.
    static let editorInset: CGFloat = 28

    /// Rectángulo del lienzo (proporción fija, centrado) dentro de una vista de tamaño `size`.
    static func fit(aspect: Float, in size: CGSize, inset: CGFloat) -> CGRect {
        let aw = max(size.width - 2 * inset, 1), ah = max(size.height - 2 * inset, 1)
        let a = CGFloat(aspect)
        let w = min(aw, ah * a), h = w / a
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    func canvasRect(in size: CGSize) -> CGRect { Self.fit(aspect: canvasAspect, in: size, inset: Self.editorInset) }

    private enum Drag {
        case none
        case points(start: SIMD2<Float>, orig: [Int: SIMD2<Float>])
        case whole(start: SIMD2<Float>, orig: [SIMD2<Float>])
        case marquee(start: SIMD2<Float>, base: Set<Int>)
    }
    private var drag: Drag = .none
    private var dragMoved = false
    private let hitRadius: CGFloat = 14

    init() {
        let env = ProcessInfo.processInfo.environment
        let demo = env["WARPCAOS_DEMO"]

        if demo == "multi" {
            var a = newSurface(); a.cols = 2; a.rows = 2; a.demoStyle = "quad"
            var b = newSurface(); b.source = .pattern(.grid); b.cols = 4; b.rows = 4
            b.demoStyle = "r:0.52,0.12,0.94,0.9,0.9"
            var c = newSurface(); c.source = .pattern(.uv); c.cols = 3; c.rows = 3; c.smooth = false
            c.opacity = 0.6; c.demoStyle = "r:0.3,0.3,0.72,0.72,0.0"
            surfaces = [a, b, c]
            selectedID = b.id
        } else if demo == "shapes" {
            var a = newSurface(); a.cols = 2; a.rows = 2; a.shape = .ellipse; a.fit = .cover
            a.demoStyle = "q:0.07,0.12,0.36,0.22,0.05,0.85,0.33,0.95"
            var b = newSurface(); b.source = .pattern(.grid); b.cols = 2; b.rows = 2; b.shape = .star; b.fit = .cover
            b.demoStyle = "r:0.4,0.1,0.64,0.9,0"
            var c = newSurface(); c.source = .pattern(.uv); c.cols = 2; c.rows = 2; c.shape = .hexagon; c.fit = .cover
            c.shapeFeather = 0.25; c.demoStyle = "r:0.7,0.1,0.95,0.9,0"
            surfaces = [a, b, c]
            selectedID = a.id
        } else if demo == "transform" {
            func panel(_ name: String, _ x0: Float) -> SurfaceModel {
                var p = newSurface(); p.name = name; p.source = .pattern(.uv); p.cols = 2; p.rows = 2
                p.demoStyle = "r:\(x0),0.22,\(x0 + 0.2),0.78,0"
                return p
            }
            let a = panel("Original", 0.03)
            var b = panel("Rotado 90", 0.26); b.contentRotation = 90
            var c = panel("Volteo H", 0.49); c.contentFlipH = true
            var d = panel("Triángulo", 0.72); d.shape = .triangle; d.fit = .cover
            d.shapeFlipV = true; d.shapeRotation = 20
            surfaces = [a, b, c, d]
            selectedID = d.id
        } else if demo == "masks" {
            var s = newSurface()
            s.cols = 2; s.rows = 2; s.demoStyle = "r:0.15,0.08,0.85,0.92,0"
            let hex = Self.ellipse(center: [0.5, 0.5], rx: 0.3, ry: 0.4, n: 6)
            let hole = Self.ellipse(center: [0.6, 0.42], rx: 0.1, ry: 0.16, n: 16)
            s.masks = [
                Mask(id: UUID(), name: "Hexágono", points: hex, feather: 40),
                Mask(id: UUID(), name: "Agujero", points: hole, feather: 24, hides: true),
            ]
            surfaces = [s]
            selectedID = s.id
            selectedMaskID = s.masks[1].id
        } else {
            var s = newSurface()
            s.demoStyle = demo
            if demo == "quad" { s.cols = 2; s.rows = 2 }
            if demo == "mesh" || demo == "linear" { s.cols = 5; s.rows = 5 }
            if demo == "linear" { s.smooth = false }
            if let link = env["WARPCAOS_URL"], let url = URL(string: link) { s.source = PageResolver.source(for: url) }
            if let path = env["WARPCAOS_FILE"] {
                let url = URL(fileURLWithPath: path)
                if MediaKind.of(url) != nil { s.source = .file(url) }
            }
            surfaces = [s]
            selectedID = s.id
        }

        configurePersistence(env: env, demo: demo)
    }

    static func ellipse(center: SIMD2<Float>, rx: Float, ry: Float, n: Int) -> [SIMD2<Float>] {
        (0..<n).map { k in
            let a = Float(k) / Float(n) * 2 * .pi - .pi / 2
            return SIMD2<Float>(center.x + rx * cos(a), center.y + ry * sin(a))
        }
    }

    private func newSurface() -> SurfaceModel {
        surfaceCounter += 1
        return SurfaceModel(id: UUID(), name: "Superficie \(surfaceCounter)")
    }

    // MARK: Acceso a la superficie activa

    var activeIndex: Int? { surfaces.firstIndex { $0.id == selectedID } }
    var active: SurfaceModel? { activeIndex.map { surfaces[$0] } }

    // MARK: Undo / redo

    private struct Snapshot {
        var surfaces: [SurfaceModel]
        var selectedID: UUID?
        var selection: Set<Int>
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastCoalesce: (key: String, time: TimeInterval)?

    private func snapshot() -> Snapshot { Snapshot(surfaces: surfaces, selectedID: selectedID, selection: selection) }

    /// Guarda el estado actual para deshacer. Con `coalesce`, los cambios seguidos con la misma clave
    /// (ej. mover un slider) comparten un solo paso de undo.
    func registerUndo(coalesce key: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        if let key, let last = lastCoalesce, last.key == key, now - last.time < 1.0 {
            lastCoalesce = (key, now)
            return
        }
        lastCoalesce = key.map { ($0, now) }
        undoStack.append(snapshot())
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoFlags()
    }

    func undoReset() { undoStack.removeAll(); redoStack.removeAll(); updateUndoFlags() }

    private func updateUndoFlags() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        drag = .none; marquee = nil; lastCoalesce = nil
        surfaces = s.surfaces.map { var x = $0; x.mesh = x.mesh; return x }   // fuerza rebuild de buffers
        selectedID = s.selectedID
        selection = s.selection
        if editingMask == nil { selectedMaskID = nil }
        updateUndoFlags()
    }

    // MARK: Superficies

    func addSurface(shape: ShapeKind = .rectangle) {
        registerUndo()
        var s = newSurface()
        applyShapeDefaults(&s, shape)
        let k = Float((surfaces.count - 1) % 6 + 1) * 0.04
        s.spawnOffset = [k, k]
        surfaces.append(s)
        selectedID = s.id
        selection = []
    }

    /// Las formas arrancan como un cuadrilátero de 4 esquinas (fácil de editar) y el contenido se recorta a ellas.
    private func applyShapeDefaults(_ s: inout SurfaceModel, _ shape: ShapeKind) {
        s.shape = shape
        s.fit = shape == .rectangle ? .stretch : .cover
        s.cols = shape == .rectangle ? 4 : 2
        s.rows = s.cols
    }

    func setShape(_ k: ShapeKind) {
        guard let i = activeIndex, surfaces[i].shape != k else { return }
        registerUndo()
        if surfaces[i].meshEdited {
            surfaces[i].shape = k
            surfaces[i].fit = k == .rectangle ? .stretch : .cover
        } else {
            applyShapeDefaults(&surfaces[i], k)
            surfaces[i].mesh = nil          // se regenera con la proporción de la forma
        }
        selection = []
    }

    func setShapeFeather(_ v: Float) {
        guard let i = activeIndex else { return }
        registerUndo(coalesce: "shapefeather")
        surfaces[i].shapeFeather = v
    }

    enum TransformTarget { case content, shape }

    private func wrapAngle(_ a: Float) -> Float {
        var v = a.truncatingRemainder(dividingBy: 360)
        if v > 180 { v -= 360 }
        if v <= -180 { v += 360 }
        return v
    }

    /// Gira el contenido o la forma `delta` grados (sentido horario).
    func rotate(_ t: TransformTarget, by delta: Float) {
        guard let i = activeIndex else { return }
        registerUndo()
        switch t {
        case .content: surfaces[i].contentRotation = wrapAngle(surfaces[i].contentRotation + delta)
        case .shape: surfaces[i].shapeRotation = wrapAngle(surfaces[i].shapeRotation + delta)
        }
    }

    func setAngle(_ t: TransformTarget, _ v: Float) {
        guard let i = activeIndex else { return }
        registerUndo(coalesce: "angle-\(t)")
        switch t {
        case .content: surfaces[i].contentRotation = v
        case .shape: surfaces[i].shapeRotation = v
        }
    }

    func flip(_ t: TransformTarget, horizontal: Bool) {
        guard let i = activeIndex else { return }
        registerUndo()
        switch (t, horizontal) {
        case (.content, true): surfaces[i].contentFlipH.toggle()
        case (.content, false): surfaces[i].contentFlipV.toggle()
        case (.shape, true): surfaces[i].shapeFlipH.toggle()
        case (.shape, false): surfaces[i].shapeFlipV.toggle()
        }
    }

    func resetTransform(_ t: TransformTarget) {
        guard let i = activeIndex else { return }
        registerUndo()
        switch t {
        case .content: surfaces[i].contentRotation = 0; surfaces[i].contentFlipH = false; surfaces[i].contentFlipV = false
        case .shape: surfaces[i].shapeRotation = 0; surfaces[i].shapeFlipH = false; surfaces[i].shapeFlipV = false
        }
    }

    func setFit(_ f: FitMode) {
        guard let i = activeIndex, surfaces[i].fit != f else { return }
        registerUndo()
        surfaces[i].fit = f
    }

    func duplicateActive() {
        guard let i = activeIndex else { return }
        registerUndo()
        var copy = surfaces[i]
        surfaceCounter += 1
        copy.id = UUID()
        copy.name = "\(copy.name) copia"
        copy.demoStyle = nil
        copy.masks = copy.masks.map { var m = $0; m = Mask(id: UUID(), name: m.name, points: m.points, feather: m.feather, inverted: m.inverted, hides: m.hides); return m }
        let shift = SIMD2<Float>(0.03, 0.03)
        if copy.mesh != nil { copy.mesh!.points = copy.mesh!.points.map { $0 + shift } }
        else { copy.spawnOffset += shift }
        copy.masks = copy.masks.map { var m = $0; m.points = m.points.map { $0 + shift }; return m }
        surfaces.insert(copy, at: i + 1)
        selectedID = copy.id
        selection = []
    }

    func deleteActive() {
        guard surfaces.count > 1, let i = activeIndex else { return }
        registerUndo()
        surfaces.remove(at: i)
        selectedID = surfaces[min(i, surfaces.count - 1)].id
        selection = []
    }

    /// delta = +1 sube la capa (se dibuja encima), -1 la baja.
    func moveActive(_ delta: Int) {
        guard let i = activeIndex, surfaces.indices.contains(i + delta) else { return }
        registerUndo()
        surfaces.swapAt(i, i + delta)
    }

    func select(_ id: UUID) {
        guard id != selectedID else { return }
        selectedID = id
        selectedMaskID = nil
        selection = []
    }

    func toggleVisible(_ id: UUID) {
        guard let i = surfaces.firstIndex(where: { $0.id == id }) else { return }
        registerUndo()
        surfaces[i].visible.toggle()
    }

    func rename(_ name: String) {
        guard let i = activeIndex else { return }
        registerUndo(coalesce: "rename")
        surfaces[i].name = name
    }

    func setOpacity(_ v: Float) {
        guard let i = activeIndex else { return }
        registerUndo(coalesce: "opacity")
        surfaces[i].opacity = v
    }

    func setPlaying(_ v: Bool) {
        guard let i = activeIndex else { return }
        surfaces[i].playing = v
    }

    func setMuted(_ v: Bool) {
        guard let i = activeIndex else { return }
        surfaces[i].muted = v
    }

    // MARK: Fuente de contenido (de la superficie activa)

    func useCalibration(_ p: Pattern) { setSource(.pattern(p)) }

    func open(url: URL) {
        if !url.isFileURL { openRemote(url); return }
        guard MediaKind.of(url) != nil else {
            status = "Formato no soportado: \(url.lastPathComponent)"
            return
        }
        setSource(.file(url))
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Elegí una imagen o un video para la superficie activa"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    /// Pide una URL y la asigna a la superficie activa.
    func openURLPanel() {
        let alert = NSAlert()
        alert.messageText = "Abrir URL"
        alert.informativeText = "Pegá un link directo a un video (.mp4, .mov, .m3u8) o a una imagen (.png, .jpg…), o el link de una página de YouTube o Vimeo (requiere yt-dlp). Se reproduce por streaming, sin descargarlo."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 24))
        field.placeholderString = "https://…/video.mp4"
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           clip.hasPrefix("http") { field.stringValue = clip }
        alert.accessoryView = field
        alert.addButton(withTitle: "Abrir")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            status = "La URL no es válida (tiene que empezar con http:// o https://)"
            return
        }
        openRemote(url)
    }

    /// Links de página (YouTube, Vimeo…) se resuelven a un stream con yt-dlp; el resto se reproduce directo.
    func openRemote(_ url: URL) {
        setSource(PageResolver.source(for: url))
    }

    private func setSource(_ s: Source) {
        guard let i = activeIndex else { return }
        registerUndo()
        surfaces[i].source = s
        surfaces[i].isVideo = false
        surfaces[i].playing = true
        status = nil
    }

    /// Lo llama el renderer cuando conoce las dimensiones reales del contenido.
    /// Si la malla no fue editada, se regenera con la proporción del contenido.
    func contentLoaded(id: UUID, aspect: Float, isVideo: Bool) {
        guard let i = surfaces.firstIndex(where: { $0.id == id }) else { return }
        if surfaces[i].isVideo != isVideo { surfaces[i].isVideo = isVideo }
        if abs(aspect - surfaces[i].contentAspect) > 0.001 {
            surfaces[i].contentAspect = aspect
            if !surfaces[i].meshEdited { surfaces[i].mesh = nil }
        }
    }

    /// Quita el cartel «Cargando…» cuando llegó el primer frame del video o terminó la descarga de la imagen.
    func finishedLoading() {
        if status?.hasPrefix("Cargando") == true { status = nil }
    }

    func contentFailed(id: UUID, message: String) {
        guard let i = surfaces.firstIndex(where: { $0.id == id }) else { return }
        surfaces[i].source = .pattern(.checkerboard)
        surfaces[i].isVideo = false
        status = message
    }

    // MARK: Malla

    func ensureMeshes(viewSize: CGSize) {
        for i in surfaces.indices where surfaces[i].mesh == nil {
            surfaces[i].mesh = makeMesh(surfaces[i], viewSize: viewSize)
            surfaces[i].demoStyle = nil
        }
    }

    private func makeMesh(_ s: SurfaceModel, viewSize: CGSize) -> Mesh {
        if let style = s.demoStyle, let m = demoMesh(style, s, viewSize) { return m }
        var m = Mesh.grid(cols: s.cols, rows: s.rows, viewSize: viewSize, smooth: s.smooth, aspect: s.meshAspect)
        if s.spawnOffset != .zero { m.points = m.points.map { $0 + s.spawnOffset } }
        return m
    }

    /// Mallas deformadas para verificar el render sin interacción (solo con WARPCAOS_DEMO).
    private func demoMesh(_ style: String, _ s: SurfaceModel, _ viewSize: CGSize) -> Mesh? {
        var m = Mesh.grid(cols: s.cols, rows: s.rows, viewSize: viewSize, smooth: s.smooth)
        let c = SIMD2<Float>(0.5, 0.5)
        if style.hasPrefix("q:") {
            let v = style.dropFirst(2).split(separator: ",").compactMap { Float($0) }
            guard v.count == 8 else { return nil }
            m.points = [[v[0], v[1]], [v[2], v[3]], [v[4], v[5]], [v[6], v[7]]]   // TL, TR, BL, BR
        } else if style == "quad" {
            m.points = [[0.08, 0.2], [0.45, 0.12], [0.12, 0.88], [0.42, 0.95]]
        } else if style.hasPrefix("r:") {
            let v = style.dropFirst(2).split(separator: ",").compactMap { Float($0) }
            guard v.count == 5 else { return nil }
            let mid = SIMD2<Float>((v[0] + v[2]) / 2, (v[1] + v[3]) / 2)
            for j in 0..<s.rows {
                for i in 0..<s.cols {
                    let u = Float(i) / Float(s.cols - 1), w = Float(j) / Float(s.rows - 1)
                    var p = SIMD2<Float>(v[0] + (v[2] - v[0]) * u, v[1] + (v[3] - v[1]) * w)
                    let d: SIMD2<Float> = p - mid
                    let scale: Float = 1 + v[4] * simd_length(d)
                    p = mid + d * scale
                    m.points[j * s.cols + i] = p
                }
            }
        } else {
            for k in 0..<m.points.count {
                let d: SIMD2<Float> = m.points[k] - c
                let scale: Float = 1.0 + 1.5 * simd_length(d)
                let shear = SIMD2<Float>(0.05 * d.y, 0)
                m.points[k] = c + d * scale + shear
            }
        }
        return m
    }

    func resetMesh() {
        guard let i = activeIndex else { return }
        registerUndo()
        surfaces[i].mesh = nil
        surfaces[i].meshEdited = false
        surfaces[i].demoStyle = nil
        selection = []
    }

    func setGrid(cols nc: Int, rows nr: Int) {
        guard let i = activeIndex else { return }
        let c = min(max(nc, 2), 16), r = min(max(nr, 2), 16)
        guard c != surfaces[i].cols || r != surfaces[i].rows else { return }
        registerUndo()
        surfaces[i].cols = c
        surfaces[i].rows = r
        if let m = surfaces[i].mesh { surfaces[i].mesh = m.resampled(cols: c, rows: r) }
        selection = []
    }

    func setSmooth(_ v: Bool) {
        guard let i = activeIndex, surfaces[i].smooth != v else { return }
        registerUndo()
        surfaces[i].smooth = v
        surfaces[i].mesh?.smooth = v
    }

    // MARK: Máscaras

    /// (índice de superficie, índice de máscara) de la máscara en edición.
    private var editingMask: (ai: Int, mi: Int)? {
        guard let ai = activeIndex, let id = selectedMaskID,
              let mi = surfaces[ai].masks.firstIndex(where: { $0.id == id }) else { return nil }
        return (ai, mi)
    }

    var isEditingMask: Bool { editingMask != nil }

    func selectMask(_ id: UUID?) {
        selectedMaskID = id
        selection = []
    }

    func addMask() {
        guard let ai = activeIndex else { return }
        registerUndo()
        // Rectángulo centrado en el 70% del bounding box de la superficie.
        let pts = surfaces[ai].mesh?.points ?? []
        var lo = SIMD2<Float>(0.3, 0.3), hi = SIMD2<Float>(0.7, 0.7)
        if let f = pts.first {
            lo = pts.reduce(f) { simd_min($0, $1) }
            hi = pts.reduce(f) { simd_max($0, $1) }
        }
        let c = (lo + hi) / 2, h = (hi - lo) * 0.35
        let rect: [SIMD2<Float>] = [[c.x - h.x, c.y - h.y], [c.x + h.x, c.y - h.y],
                                    [c.x + h.x, c.y + h.y], [c.x - h.x, c.y + h.y]]
        let m = Mask(id: UUID(), name: "Máscara \(surfaces[ai].masks.count + 1)", points: rect)
        surfaces[ai].masks.append(m)
        selectMask(m.id)
    }

    func deleteMask(_ id: UUID) {
        guard let ai = activeIndex, let mi = surfaces[ai].masks.firstIndex(where: { $0.id == id }) else { return }
        registerUndo()
        surfaces[ai].masks.remove(at: mi)
        if selectedMaskID == id { selectedMaskID = nil }
        selection = []
    }

    private func updateMask(coalesce key: String, _ f: (inout Mask) -> Void) {
        guard let (ai, mi) = editingMask else { return }
        registerUndo(coalesce: key)
        f(&surfaces[ai].masks[mi])
    }

    func setMaskFeather(_ v: Float) { updateMask(coalesce: "feather") { $0.feather = v } }
    func setMaskInverted(_ v: Bool) { updateMask(coalesce: "invert") { $0.inverted = v } }
    func setMaskHides(_ v: Bool) { updateMask(coalesce: "hides") { $0.hides = v } }
    func renameMask(_ name: String) { updateMask(coalesce: "maskname") { $0.name = name } }

    // MARK: Puntos editables (malla de la superficie activa o vértices de la máscara en edición)

    func currentPoints() -> [SIMD2<Float>]? {
        if let (ai, mi) = editingMask { return surfaces[ai].masks[mi].points }
        return active?.mesh?.points
    }

    private func writePoints(_ pts: [SIMD2<Float>]) {
        if let (ai, mi) = editingMask { surfaces[ai].masks[mi].points = pts }
        else if let ai = activeIndex { surfaces[ai].mesh?.points = pts }
    }

    private func currentContains(_ n: SIMD2<Float>) -> Bool {
        if let (ai, mi) = editingMask { return Self.polygonContains(surfaces[ai].masks[mi].points, n) }
        return active?.mesh?.contains(n) ?? false
    }

    static func polygonContains(_ poly: [SIMD2<Float>], _ pt: SIMD2<Float>) -> Bool {
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

    // MARK: Mouse (puntos de vista, origen arriba-izquierda)

    /// Punto de vista → coordenadas normalizadas del lienzo.
    private func norm(_ p: CGPoint, _ size: CGSize) -> SIMD2<Float> {
        let r = canvasRect(in: size)
        return [Float((p.x - r.minX) / r.width), Float((p.y - r.minY) / r.height)]
    }

    private func toPoint(_ n: SIMD2<Float>, _ size: CGSize) -> CGPoint {
        let r = canvasRect(in: size)
        return CGPoint(x: r.minX + CGFloat(n.x) * r.width, y: r.minY + CGFloat(n.y) * r.height)
    }

    func mouseDown(_ p: CGPoint, size: CGSize, shift: Bool) {
        dragMoved = false
        let n = norm(p, size)

        // 1. Nodos del objeto en edición (malla de la superficie activa o máscara).
        if let pts = currentPoints() {
            var best: (Int, CGFloat)?
            for (i, c) in pts.enumerated() {
                let q = toPoint(c, size)
                let d = hypot(q.x - p.x, q.y - p.y)
                if d <= hitRadius, d < (best?.1 ?? .infinity) { best = (i, d) }
            }
            if let (i, _) = best {
                if shift {
                    if selection.contains(i) { selection.remove(i); drag = .none; return }
                    selection.insert(i)
                } else if !selection.contains(i) {
                    selection = [i]
                }
                drag = .points(start: n, orig: Dictionary(uniqueKeysWithValues: selection.map { ($0, pts[$0]) }))
                return
            }
        }

        // 2. Shift = selección rectangular aditiva.
        if shift {
            drag = .marquee(start: n, base: selection)
            marquee = (n, n)
            return
        }

        // 3a. Editando una máscara: clic dentro la mueve entera.
        if isEditingMask {
            if currentContains(n), let pts = currentPoints() {
                drag = .whole(start: n, orig: pts)
                return
            }
        // 3b. Superficie visible más alta bajo el cursor: la selecciona y arrastra entera.
        } else if let hit = surfaces.indices.reversed().first(where: {
            surfaces[$0].visible && surfaces[$0].mesh?.contains(n) == true
        }) {
            select(surfaces[hit].id)
            drag = .whole(start: n, orig: surfaces[hit].mesh!.points)
            return
        }

        // 4. Vacío: selección rectangular.
        selection = []
        drag = .marquee(start: n, base: [])
        marquee = (n, n)
    }

    /// Doble clic sobre una arista de la máscara en edición: inserta un vértice.
    func doubleClick(_ p: CGPoint, size: CGSize) {
        guard let (ai, mi) = editingMask else { return }
        let pts = surfaces[ai].masks[mi].points
        guard pts.count < Mask.maxPoints else { return }
        var best: (Int, CGFloat, CGPoint)?
        for i in 0..<pts.count {
            let a = toPoint(pts[i], size)
            let b = toPoint(pts[(i + 1) % pts.count], size)
            let e = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let len2 = max(e.x * e.x + e.y * e.y, 1e-6)
            let t = min(max(((p.x - a.x) * e.x + (p.y - a.y) * e.y) / len2, 0), 1)
            let q = CGPoint(x: a.x + e.x * t, y: a.y + e.y * t)
            let d = hypot(p.x - q.x, p.y - q.y)
            if d < 10, d < (best?.1 ?? .infinity) { best = (i, d, q) }
        }
        guard let (i, _, q) = best else { return }
        registerUndo()
        surfaces[ai].masks[mi].points.insert(norm(q, size), at: i + 1)
        selection = [i + 1]
        drag = .none
    }

    func mouseDragged(_ p: CGPoint, size: CGSize) {
        let n = norm(p, size)
        guard activeIndex != nil else { return }

        switch drag {
        case .none: break
        case .points(let start, let orig):
            beginEditIfNeeded()
            let delta = n - start
            var pts = currentPoints() ?? []
            for (i, o) in orig where i < pts.count { pts[i] = clamp(o + delta) }
            writePoints(pts)
        case .whole(let start, let orig):
            beginEditIfNeeded()
            let delta = n - start
            writePoints(orig.map { clamp($0 + delta) })
        case .marquee(let start, let base):
            marquee = (start, n)
            let lo = simd_min(start, n), hi = simd_max(start, n)
            var sel = base
            for (i, c) in (currentPoints() ?? []).enumerated()
            where c.x >= lo.x && c.x <= hi.x && c.y >= lo.y && c.y <= hi.y { sel.insert(i) }
            selection = sel
        }
    }

    /// Un solo paso de undo por arrastre, registrado al primer movimiento real.
    private func beginEditIfNeeded() {
        guard !dragMoved, let ai = activeIndex else { return }
        dragMoved = true
        registerUndo()
        if !isEditingMask { surfaces[ai].meshEdited = true }
    }

    func mouseUp() { drag = .none; marquee = nil }

    private func clamp(_ v: SIMD2<Float>) -> SIMD2<Float> {
        [min(max(v.x, -0.5), 1.5), min(max(v.y, -0.5), 1.5)]
    }

    // MARK: Teclado

    func selectAll() { selection = Set(0..<(currentPoints()?.count ?? 0)) }

    /// Devuelve true si la tecla fue consumida.
    func keyDown(keyCode: UInt16, chars: String, shift: Bool, size: CGSize) -> Bool {
        let step: Float = shift ? 10 : 1
        let cr = canvasRect(in: size)
        let dx = step / Float(cr.width), dy = step / Float(cr.height)
        switch keyCode {
        case 123: nudge([-dx, 0])
        case 124: nudge([dx, 0])
        case 125: nudge([0, dy])
        case 126: nudge([0, -dy])
        case 53:
            if !selection.isEmpty { selection = [] } else if isEditingMask { selectMask(nil) }
        case 51, 117: deleteSelectedVertices()
        case 48:
            let n = currentPoints()?.count ?? 0
            guard n > 0 else { return true }
            let cur = selection.count == 1 ? selection.first! : (shift ? 0 : -1)
            selection = [((cur + (shift ? -1 : 1)) % n + n) % n]
        default:
            switch chars.lowercased() {
            case " ": if let a = active, a.isVideo { setPlaying(!a.playing) }
            case "r": resetMesh()
            case "h": showOverlay.toggle()
            default: return false
            }
        }
        return true
    }

    private func nudge(_ d: SIMD2<Float>) {
        guard !selection.isEmpty, var pts = currentPoints() else { return }
        registerUndo(coalesce: "nudge")
        for i in selection where i < pts.count { pts[i] = clamp(pts[i] + d) }
        writePoints(pts)
        if !isEditingMask, let ai = activeIndex { surfaces[ai].meshEdited = true }
    }

    /// Borra los vértices seleccionados de la máscara en edición (mínimo 3 vértices).
    private func deleteSelectedVertices() {
        guard let (ai, mi) = editingMask, !selection.isEmpty else { return }
        let pts = surfaces[ai].masks[mi].points
        let kept = pts.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        guard kept.count >= 3 else { return }
        registerUndo()
        surfaces[ai].masks[mi].points = kept
        selection = []
    }
}
