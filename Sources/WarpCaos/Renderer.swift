import MetalKit
import QuartzCore

/// Debe coincidir con `FragUniform` y `MaskInfo` del shader.
private struct FragUniform {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var opacity: Float
    var maskCount: UInt32
    var shape: UInt32
    var shapeFeather: Float
    var uvM0: SIMD2<Float>
    var uvM1: SIMD2<Float>
    var shM0: SIMD2<Float>
    var shM1: SIMD2<Float>
    var uv2M0: SIMD2<Float>
    var uv2M1: SIMD2<Float>
    var mixAmount: Float
    var pad: Float
}

private struct MaskInfo {
    var start: UInt32
    var count: UInt32
    var feather: Float
    var flags: UInt32
}

/// Un contenido cargado (patrón, imagen o video) listo para dibujarse. Cada elemento de la lista de una superficie tiene el suyo.
private final class MediaSlot {
    let source: Source
    var texture: MTLTexture?
    var video: VideoSource?
    var aspect: Float = 1
    var isVideo = false
    /// Ya hay imagen para mostrar (textura lista o primer frame recibido).
    var sizeReported = false
    var failure: String?
    var readyAt: Date?
    var retries = 0
    var wasPlaying = true
    /// Se está precargando en silencio para el próximo fundido.
    var preload = false
    /// Instante (CACurrentMediaTime) desde el que cuenta su duración, para imágenes y patrones.
    var startedAt: Double = 0
    /// Invalida respuestas asíncronas (descarga, yt-dlp) de una carga anterior.
    var loadToken = 0
    /// Posición de este contenido en `items` de la superficie.
    var index = 0

    init(source: Source) { self.source = source }
}

/// Recursos de GPU y de reproducción de una superficie.
private final class Resources {
    // Lista de reproducción: contenido actual, siguiente (precargado) y progreso del fundido.
    var cur: MediaSlot?
    var next: MediaSlot?
    var itemsKey: [Source] = []
    var order: [Int] = []
    var pendingOrder: [Int]?
    var pos = 0
    var fadeStart: Double?
    var mix: Float = 0
    var reported = false
    var failureReported = false
    var consecutiveFailures = 0
    var lastTick = CACurrentMediaTime()
    var lastPublished: PlaybackInfo?

    // Malla.
    var revision = -1
    var vertexBuffer: MTLBuffer?
    var indexBuffer: MTLBuffer?
    var indexCount = 0
    var lineBuffer: MTLBuffer?
    var lineVertexCount = 0
}

final class Renderer: NSObject, MTKViewDelegate {
    /// Muestras MSAA (bordes de superficies y overlay sin escalones). Las vistas deben usar el mismo valor.
    static let sampleCount = 4

    let device: MTLDevice
    let state: AppState
    private let queue: MTLCommandQueue
    private var meshPipeline: MTLRenderPipelineState?
    private var overlayPipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private let textureLoader: MTKTextureLoader
    private var resources: [UUID: Resources] = [:]

    init(state: AppState) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal no disponible")
        }
        self.device = device
        self.queue = queue
        self.state = state
        self.textureLoader = MTKTextureLoader(device: device)
        super.init()
        buildPipelines()
    }

    private func alphaBlend(_ ca: MTLRenderPipelineColorAttachmentDescriptor) {
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    private func buildPipelines() {
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)

            let q = MTLRenderPipelineDescriptor()
            q.vertexFunction = library.makeFunction(name: "vertex_main")
            q.fragmentFunction = library.makeFunction(name: "fragment_main")
            q.rasterSampleCount = Renderer.sampleCount
            alphaBlend(q.colorAttachments[0])
            meshPipeline = try device.makeRenderPipelineState(descriptor: q)

            let o = MTLRenderPipelineDescriptor()
            o.vertexFunction = library.makeFunction(name: "overlay_vertex")
            o.fragmentFunction = library.makeFunction(name: "overlay_fragment")
            o.rasterSampleCount = Renderer.sampleCount
            alphaBlend(o.colorAttachments[0])
            overlayPipeline = try device.makeRenderPipelineState(descriptor: o)

            let s = MTLSamplerDescriptor()
            s.minFilter = .linear
            s.magFilter = .linear
            s.mipFilter = .linear
            s.maxAnisotropy = 8
            sampler = device.makeSamplerState(descriptor: s)
        } catch {
            fatalError("Error compilando shaders: \(error)")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func buffer<T>(_ array: [T]) -> MTLBuffer? {
        array.isEmpty ? nil : device.makeBuffer(bytes: array, length: array.count * MemoryLayout<T>.stride,
                                                options: .storageModeShared)
    }

    func draw(in view: MTKView) { render(view, editor: true) }

    /// Sincroniza contenido y mallas (idempotente: lo pueden llamar el editor y la salida).
    private func prepare(canvasSize: CGSize) {
        for s in state.surfaces {
            let r = resources[s.id] ?? Resources()
            resources[s.id] = r
            syncSurface(r, s)
        }
        let alive = Set(state.surfaces.map(\.id))
        for k in resources.keys where !alive.contains(k) { resources[k] = nil }

        state.ensureMeshes(viewSize: canvasSize)
        for s in state.surfaces {
            guard let r = resources[s.id], let mesh = s.mesh, r.revision != s.revision else { continue }
            let g = mesh.buildGrid()
            r.vertexBuffer = buffer(g.vertices)
            r.indexBuffer = buffer(g.indices)
            r.indexCount = g.indices.count
            r.lineBuffer = buffer(g.lines)
            r.lineVertexCount = g.lines.count / 2
            r.revision = s.revision
        }
    }

    /// Dibuja el lienzo en `view`. `editor` agrega margen, overlays y el fondo del lienzo.
    func render(_ view: MTKView, editor: Bool) {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let rect = AppState.fit(aspect: state.canvasAspect, in: size, inset: editor ? AppState.editorInset : 0)
        if editor { state.viewSize = rect.size }
        prepare(canvasSize: rect.size)
        let surfaces = state.surfaces

        guard let meshPipeline, let overlayPipeline, let sampler,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        if !editor && state.blackout {
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
            return
        }

        // Geometría del lienzo en píxeles del drawable.
        let dw = view.drawableSize.width, dh = view.drawableSize.height
        let scale = dw / size.width
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let canvasViewport = MTLViewport(originX: Double(px.minX), originY: Double(px.minY),
                                         width: Double(px.width), height: Double(px.height), znear: 0, zfar: 1)
        let sx = min(max(Int(px.minX.rounded()), 0), Int(dw) - 1), sy = min(max(Int(px.minY.rounded()), 0), Int(dh) - 1)
        let canvasScissor = MTLScissorRect(x: sx, y: sy,
                                           width: max(min(Int(px.width.rounded()), Int(dw) - sx), 1),
                                           height: max(min(Int(px.height.rounded()), Int(dh) - sy), 1))
        let fullViewport = MTLViewport(originX: 0, originY: 0, width: Double(dw), height: Double(dh), znear: 0, zfar: 1)
        let fullScissor = MTLScissorRect(x: 0, y: 0, width: Int(dw), height: Int(dh))

        enc.setViewport(canvasViewport)
        enc.setScissorRect(canvasScissor)

        // Fondo del lienzo.
        enc.setRenderPipelineState(overlayPipeline)
        var black: SIMD4<Float> = [0, 0, 0, 1]
        let quad: [Float] = [-1, -1, 1, -1, -1, 1, 1, 1]
        enc.setVertexBytes(quad, length: quad.count * 4, index: 0)
        enc.setFragmentBytes(&black, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Superficies de abajo hacia arriba.
        enc.setRenderPipelineState(meshPipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        let viewport = SIMD2<Float>(Float(px.width), Float(px.height))
        let origin = SIMD2<Float>(Float(px.minX), Float(px.minY))
        let pixelScale = Float(scale)
        for s in surfaces where s.visible {
            guard let r = resources[s.id], let tex = r.cur?.texture,
                  let vb = r.vertexBuffer, let ib = r.indexBuffer else { continue }

            // Máscaras: hasta 8 y 400 vértices por superficie (límite de 4 KB de setFragmentBytes).
            var pts: [SIMD2<Float>] = []
            var infos: [MaskInfo] = []
            for m in s.masks where m.points.count >= 3 && infos.count < 8 && pts.count + m.points.count <= 400 {
                infos.append(MaskInfo(start: UInt32(pts.count), count: UInt32(m.points.count),
                                      feather: m.feather * pixelScale,
                                      flags: (m.inverted ? 1 : 0) | (m.hides ? 2 : 0)))
                pts += m.points
            }
            let maskCount = infos.count
            if infos.isEmpty { pts = [.zero]; infos = [MaskInfo(start: 0, count: 0, feather: 0, flags: 0)] }
            let cm = s.contentMatrix(aspect: r.cur?.aspect ?? s.contentAspect), sm = s.shapeMatrix
            // Durante un fundido de la lista se mezcla con el contenido siguiente.
            var cm2 = (SIMD2<Float>(0, 0), SIMD2<Float>(0, 0)), mixAmount: Float = 0, tex2 = tex
            if r.mix > 0, let nx = r.next, let t2 = nx.texture {
                cm2 = s.contentMatrix(aspect: nx.aspect)
                mixAmount = r.mix
                tex2 = t2
            }
            var u = FragUniform(viewport: viewport, origin: origin, opacity: s.opacity, maskCount: UInt32(maskCount),
                                shape: s.shape.shaderID, shapeFeather: s.shapeFeather,
                                uvM0: cm.0, uvM1: cm.1, shM0: sm.0, shM1: sm.1,
                                uv2M0: cm2.0, uv2M1: cm2.1, mixAmount: mixAmount, pad: 0)

            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentTexture(tex2, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<FragUniform>.stride, index: 0)
            enc.setFragmentBytes(pts, length: pts.count * MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.setFragmentBytes(infos, length: infos.count * MemoryLayout<MaskInfo>.stride, index: 2)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: r.indexCount, indexType: .uint32,
                                      indexBuffer: ib, indexBufferOffset: 0)
        }

        if editor && state.showOverlay {
            drawOverlay(enc, surfaces: surfaces, size: size, rect: rect, pipeline: overlayPipeline,
                        full: (fullViewport, fullScissor), canvas: (canvasViewport, canvasScissor))
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: Lista de reproducción y contenido

    private static let log = ProcessInfo.processInfo.environment["WARPCAOS_LOG"] != nil
    private let t0 = CACurrentMediaTime()
    private func logEvent(_ s: @autoclosure () -> String) {
        if Renderer.log { print(String(format: "[%7.2f] ", CACurrentMediaTime() - t0) + s()); fflush(stdout) }
    }

    private static let imageOptions: [MTKTextureLoader.Option: Any] = [
        .SRGB: false,
        .origin: MTKTextureLoader.Origin.topLeft,
        .generateMipmaps: true,
    ]

    private func makeOrder(_ n: Int, shuffle: Bool, avoidFirst: Int?) -> [Int] {
        var o = Array(0..<n)
        if shuffle {
            o.shuffle()
            if let a = avoidFirst, n > 1, o.first == a { o.swapAt(0, 1) }   // no repetir el último contenido seguido
        }
        return o
    }

    private func resetPlaylist(_ r: Resources, _ s: SurfaceModel, _ items: [Source]) {
        r.cur?.video?.player.pause()
        r.itemsKey = items
        r.order = makeOrder(items.count, shuffle: s.playlistShuffle, avoidFirst: nil)
        r.pendingOrder = nil
        r.pos = 0
        r.next = nil
        r.fadeStart = nil
        r.mix = 0
        r.reported = false
        r.failureReported = false
        r.consecutiveFailures = 0
        let slot = MediaSlot(source: items[r.order[0]])
        slot.index = r.order[0]
        r.cur = slot
        logEvent("lista: \(items.count) contenido(s), empieza «\(slot.source.displayName)»")
        loadSlot(slot, s)
    }

    /// Índice (en `items`) del contenido que sigue al actual.
    private func nextIndex(_ r: Resources, _ s: SurfaceModel) -> Int {
        if r.pos + 1 < r.order.count { return r.order[r.pos + 1] }
        if r.pendingOrder == nil {
            r.pendingOrder = makeOrder(r.order.count, shuffle: s.playlistShuffle, avoidFirst: r.order.last)
        }
        return r.pendingOrder![0]
    }

    private func advanceOrder(_ r: Resources) {
        if r.pos + 1 < r.order.count { r.pos += 1 } else {
            r.order = r.pendingOrder ?? r.order
            r.pendingOrder = nil
            r.pos = 0
        }
    }

    /// Segundos que le quedan al contenido actual (nil si todavía no empezó a mostrarse).
    private func timeLeft(_ slot: MediaSlot, _ s: SurfaceModel, _ now: Double) -> Double? {
        guard slot.sizeReported else { return nil }
        // Por tiempo: todos duran lo mismo (los videos cortos se repiten solos hasta completarlo, los largos se cortan).
        if s.playlistMode == .time { return Double(s.playlistSeconds) - (now - slot.startedAt) }
        if let v = slot.video, let d = v.durationSeconds {
            let total = Double(max(1, s.playlistLoops)) * d
            return total - (Double(v.loopCount) * d + v.currentSeconds)
        }
        return Double(s.playlistStillSeconds) - (now - slot.startedAt)
    }

    private func syncSurface(_ r: Resources, _ s: SurfaceModel) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - r.lastTick, 0), 0.5)
        r.lastTick = now

        let items = s.items
        if r.itemsKey != items { resetPlaylist(r, s, items) }
        guard let cur = r.cur else { return }

        syncSlot(cur, s)
        if let nx = r.next { syncSlot(nx, s) }

        // Reproducción: pausa y silencio de la superficie (el siguiente se mantiene en silencio hasta su fundido).
        if let v = cur.video {
            if s.playing != cur.wasPlaying {
                cur.wasPlaying = s.playing
                s.playing ? v.player.play() : v.player.pause()
            }
            if v.player.isMuted != s.muted { v.player.isMuted = s.muted }
        }
        if !s.playing { cur.startedAt += dt }   // el reloj de imágenes y patrones se detiene con la pausa

        // Primer frame del contenido actual: informa proporción y tipo, y apaga el cartel «Cargando…».
        if cur.sizeReported, !r.reported {
            r.reported = true
            cur.startedAt = now
            state.contentLoaded(id: s.id, aspect: cur.aspect, isVideo: cur.isVideo)
            state.finishedLoading()
        }

        guard items.count > 1 else {
            state.setPlayback(s.id, nil)
            // Un solo contenido: se repite sin fin; si falla, se vuelve al tablero.
            if let f = cur.failure, !r.failureReported {
                r.failureReported = true
                state.contentFailed(id: s.id, message: f)
            }
            return
        }
        advancePlaylist(r, s, cur, now)

        // Progreso para el panel: contenido actual y segundos restantes (se publica solo cuando cambia).
        if let c = r.cur {
            let info = PlaybackInfo(index: c.index, remaining: timeLeft(c, s, now).map { max(0, Int($0.rounded(.up))) })
            if info != r.lastPublished { r.lastPublished = info; state.setPlayback(s.id, info) }
        }
    }

    private func advancePlaylist(_ r: Resources, _ s: SurfaceModel, _ cur: MediaSlot, _ now: Double) {
        let n = r.itemsKey.count
        let curFailed = cur.failure != nil
        let fade = curFailed ? 0 : Double(min(max(s.playlistFade, 0), 3))
        let left: Double? = curFailed ? 0 : timeLeft(cur, s, now)

        if curFailed, !r.failureReported {
            r.consecutiveFailures += 1
            state.status = "Se salteó «\(cur.source.displayName)»: \(cur.failure ?? "")"
            if r.consecutiveFailures >= n {
                r.failureReported = true
                state.contentFailed(id: s.id, message: cur.failure ?? "No se pudo reproducir ningún contenido de la lista")
                return
            }
        }

        // Precarga del siguiente, con margen para que esté listo cuando empiece el fundido.
        if r.next == nil, let left {
            let upcomingIndex = nextIndex(r, s)
            let upcoming = r.itemsKey[upcomingIndex]
            var lead = 1.0
            switch upcoming {
            case .file(let u): lead = MediaKind.of(u) == .video ? 2.0 : 0.5
            case .url, .page: lead = 8.0
            case .pattern: lead = 0.5
            }
            if left <= fade + lead {
                let slot = MediaSlot(source: upcoming)
                slot.index = upcomingIndex
                slot.preload = true
                r.next = slot
                logEvent("precarga «\(upcoming.displayName)» (faltan \(String(format: "%.1f", left)) s)")
                loadSlot(slot, s)
            }
        }

        guard let nx = r.next else { return }

        if nx.failure != nil {
            // Un contenido que no carga se saltea: la lista sigue con el siguiente.
            r.consecutiveFailures += 1
            state.status = "Se salteó «\(nx.source.displayName)»: \(nx.failure ?? "")"
            logEvent("falló «\(nx.source.displayName)»: \(nx.failure ?? "")")
            r.next = nil
            advanceOrder(r)
            if r.consecutiveFailures >= n && !r.failureReported {
                r.failureReported = true
                state.contentFailed(id: s.id, message: "No se pudo reproducir ningún contenido de la lista")
            }
            return
        }

        // Empieza el fundido cuando al actual le queda `fade` y el siguiente ya tiene imagen.
        if r.fadeStart == nil, nx.texture != nil, nx.sizeReported, let left, left <= fade {
            r.fadeStart = now
            nx.startedAt = now
            nx.preload = false
            if let v = nx.video {
                v.player.seek(to: .zero)
                if s.playing { v.player.play() }
                v.player.isMuted = s.muted
            }
            logEvent("fundido «\(cur.source.displayName)» → «\(nx.source.displayName)» (\(String(format: "%.1f", fade)) s)")
        }

        guard let start = r.fadeStart else { return }
        let m = fade <= 0.01 ? 1.0 : min(1.0, (now - start) / fade)
        r.mix = Float(m)
        // Audio: el que sale baja y el que entra sube.
        cur.video?.player.volume = Float(1 - m)
        nx.video?.player.volume = Float(m)

        if m >= 1 {
            cur.video?.player.pause()
            r.cur = nx
            r.next = nil
            r.fadeStart = nil
            r.mix = 0
            r.consecutiveFailures = 0
            nx.video?.player.volume = 1
            advanceOrder(r)
            state.contentLoaded(id: s.id, aspect: nx.aspect, isVideo: nx.isVideo)
            logEvent("ahora «\(nx.source.displayName)»")
        }
    }

    /// Actualiza un contenido cada frame: textura del video, errores y detección de códecs no soportados.
    private func syncSlot(_ slot: MediaSlot, _ s: SurfaceModel) {
        guard let video = slot.video, slot.failure == nil else { return }

        if let msg = video.errorMessage {
            // Las URL de stream de una página vencen: se vuelve a resolver (hasta 3 veces) antes de rendirse.
            if case .page = slot.source, slot.retries < 3 {
                slot.retries += 1
                loadSlot(slot, s)
                return
            }
            slot.failure = "No se pudo reproducir el video: \(msg)"
            return
        }
        // Video "listo" que no entrega imágenes: casi siempre un códec que AVFoundation no decodifica.
        if (s.playing || slot.preload), video.isReady, !slot.sizeReported {
            let since = slot.readyAt ?? Date()
            slot.readyAt = since
            if Date().timeIntervalSince(since) > 3 {
                slot.failure = "El video no entrega imágenes: probablemente usa un códec no compatible. Convertilo a H.264 (MP4), por ejemplo con ffmpeg."
                return
            }
        }
        if video.update(), let t = video.texture {
            slot.texture = t
            if !slot.sizeReported {
                slot.sizeReported = true
                slot.retries = 0
                slot.aspect = Float(t.width) / Float(t.height)
            }
        }
    }

    // MARK: Carga de un contenido

    private func loadSlot(_ slot: MediaSlot, _ s: SurfaceModel) {
        slot.loadToken += 1
        let token = slot.loadToken
        slot.video = nil
        slot.texture = nil
        slot.sizeReported = false
        slot.failure = nil
        slot.readyAt = nil
        let id = s.id
        let announce = !slot.preload   // los carteles «Cargando…» son solo del contenido que se está mostrando

        switch slot.source {
        case .pattern(let p):
            slot.texture = Generators.texture(device: device, pattern: p)
            slot.aspect = 1
            slot.isVideo = false
            slot.sizeReported = slot.texture != nil

        case .file(let url):
            switch MediaKind.of(url) {
            case .image:
                do {
                    let t = try textureLoader.newTexture(URL: url, options: Renderer.imageOptions)
                    setImage(slot, t)
                } catch {
                    slot.failure = "No se pudo abrir la imagen: \(error.localizedDescription)"
                }
            case .video:
                startVideo(slot, s.playing, s.muted, url)
            case nil:
                slot.failure = "Formato no soportado"
            }

        case .page(let page):
            if announce { state.status = "Resolviendo \(page.host ?? "link")…" }
            PageResolver.resolve(page) { [weak self, weak slot] result in
                DispatchQueue.main.async {
                    guard let self, let slot, slot.loadToken == token,
                          let cur = self.state.surfaces.first(where: { $0.id == id }) else { return }
                    switch result {
                    case .success(let resolved):
                        if announce { self.state.status = "Cargando «\(resolved.title)»…" }
                        self.startVideo(slot, cur.playing, cur.muted, resolved.stream)
                    case .failure(.notInstalled):
                        slot.failure = "Para abrir links de YouTube o Vimeo hace falta yt-dlp. Instalalo con «brew install yt-dlp» y volvé a intentar."
                    case .failure(.blocked(let site)):
                        slot.failure = "\(site) bloquea el streaming a reproductores externos. Descargalo con «yt-dlp -f b[ext=mp4] <link>» y abrilo como archivo."
                    case .failure(.failed(let why)):
                        slot.failure = "No se pudo resolver el link: \(why)"
                    }
                }
            }

        case .url(let url):
            if announce { state.status = "Cargando \(url.host ?? "URL")…" }
            switch MediaKind.forRemote(url) {
            case .video: startVideo(slot, s.playing, s.muted, url)
            case .image: loadRemoteImage(slot, token, url)
            }
        }
    }

    private func setImage(_ slot: MediaSlot, _ t: MTLTexture) {
        slot.texture = t
        slot.aspect = Float(t.width) / Float(t.height)
        slot.isVideo = false
        slot.sizeReported = true
    }

    private func startVideo(_ slot: MediaSlot, _ playing: Bool, _ muted: Bool, _ url: URL) {
        guard let v = VideoSource(url: url, device: device) else {
            slot.failure = "No se pudo abrir el video"
            return
        }
        slot.video = v
        slot.isVideo = true
        slot.wasPlaying = playing
        // Un contenido precargado corre en silencio hasta que empieza su fundido.
        v.player.isMuted = slot.preload ? true : muted
        v.player.volume = slot.preload ? 0 : 1
        if playing { v.player.play() }
    }

    /// Descarga la imagen en segundo plano; si mientras tanto el contenido se recargó o se descartó, se ignora.
    private func loadRemoteImage(_ slot: MediaSlot, _ token: Int, _ url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self, weak slot] data, response, error in
            DispatchQueue.main.async {
                guard let self, let slot, slot.loadToken == token else { return }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard let data, error == nil, code < 400 else {
                    slot.failure = "No se pudo descargar la imagen: \(error?.localizedDescription ?? "HTTP \(code)")"
                    return
                }
                do {
                    self.setImage(slot, try self.textureLoader.newTexture(data: data, options: Renderer.imageOptions))
                } catch {
                    slot.failure = "La URL no es una imagen válida: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    // MARK: Overlay

    private func drawOverlay(_ enc: MTLRenderCommandEncoder, surfaces: [SurfaceModel], size: CGSize, rect: CGRect,
                             pipeline: MTLRenderPipelineState,
                             full: (MTLViewport, MTLScissorRect), canvas: (MTLViewport, MTLScissorRect)) {
        enc.setRenderPipelineState(pipeline)

        func color(_ c: SIMD4<Float>) {
            var c = c
            enc.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        }
        func bind(_ data: [Float]) {
            if data.count * 4 <= 4000 {
                enc.setVertexBytes(data, length: data.count * 4, index: 0)
            } else if let b = buffer(data) {
                enc.setVertexBuffer(b, offset: 0, index: 0)
            }
        }

        // Isolíneas de las mallas (coordenadas del lienzo, recortadas a él).
        enc.setViewport(canvas.0)
        enc.setScissorRect(canvas.1)
        // Dos pasadas: sombra oscura desplazada 1,5 px y línea clara encima (legible sobre fondos claros u oscuros).
        for pass in 0..<2 {
            var vp = canvas.0
            if pass == 0 { vp.originX += 1.5; vp.originY += 1.5 }
            enc.setViewport(vp)
            for s in surfaces where s.visible {
                guard let r = resources[s.id], let lb = r.lineBuffer else { continue }
                let active = s.id == state.selectedID
                enc.setVertexBuffer(lb, offset: 0, index: 0)
                if pass == 0 { color([0, 0, 0, active ? 0.55 : 0.25]) }
                else { color([1, 1, 1, active ? 0.85 : 0.3]) }
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: r.lineVertexCount)
            }
        }

        // Contorno de la forma de la superficie activa (sigue la perspectiva y la deformación).
        enc.setViewport(canvas.0)
        if let a = state.active, a.shape != .rectangle, a.visible, let mesh = a.mesh {
            var line: [Float] = []
            let outline = a.shape.outlineUV(angle: a.shapeRotation, flipH: a.shapeFlipH, flipV: a.shapeFlipV)
            for k in 0...outline.count {
                let uv = outline[k % outline.count]
                let q = Mesh.ndc(mesh.screenPoint(u: uv.x, v: uv.y))
                line += [q.x, q.y]
            }
            bind(line); color([1, 0.45, 0.9, 0.95])
            enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: outline.count + 1)
        }

        // Resto del overlay sobre la vista completa, para poder ver y tomar nodos fuera del lienzo.
        enc.setViewport(full.0)
        enc.setScissorRect(full.1)

        /// Coordenadas normalizadas del lienzo → NDC de la vista.
        func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> {
            let x = (Float(rect.minX) + p.x * Float(rect.width)) / Float(size.width)
            let y = (Float(rect.minY) + p.y * Float(rect.height)) / Float(size.height)
            return [2 * x - 1, 1 - 2 * y]
        }

        // Borde del lienzo.
        let corners: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]
        var border: [Float] = []
        for c in corners { let q = ndc(c); border += [q.x, q.y] }
        bind(border); color([1, 1, 1, 0.3])
        enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: 5)

        // Contornos de las máscaras de la superficie activa.
        guard let active = state.active else { return }
        let editingID = state.selectedMaskID
        for m in active.masks where m.points.count >= 3 {
            var line: [Float] = []
            for i in 0...m.points.count {
                let q = ndc(m.points[i % m.points.count])
                line += [q.x, q.y]
            }
            bind(line)
            color(m.id == editingID ? [0.3, 1, 0.4, 0.95] : [0.3, 1, 0.4, 0.4])
            enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: m.points.count + 1)
        }

        // Nodos (de la malla, o de la máscara en edición) y rectángulo de selección.
        guard let points = state.currentPoints() else { return }
        let editingMask = state.isEditingMask
        let hx = Float(6 / size.width) * 2, hy = Float(6 / size.height) * 2
        func handles(selected: Bool) -> [Float] {
            var v: [Float] = []
            for (i, pt) in points.enumerated() where state.selection.contains(i) == selected {
                let c = ndc(pt)
                let (l, r, t, b) = (c.x - hx, c.x + hx, c.y - hy, c.y + hy)
                v += [l, t, r, t, l, b, r, t, r, b, l, b]
            }
            return v
        }
        let normal = handles(selected: false), picked = handles(selected: true)
        let normalColor: SIMD4<Float> = editingMask ? [0.3, 1, 0.4, 1] : [0.2, 0.7, 1, 1]
        if !normal.isEmpty { bind(normal); color(normalColor); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: normal.count / 2) }
        if !picked.isEmpty { bind(picked); color([1, 0.55, 0.1, 1]); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: picked.count / 2) }

        if let (a, b) = state.marquee {
            let p0 = ndc(a), p1 = ndc(b)
            let r: [Float] = [p0.x, p0.y, p1.x, p0.y, p1.x, p1.y, p0.x, p1.y, p0.x, p0.y]
            bind(r); color([1, 0.55, 0.1, 0.9])
            enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: 5)
        }
    }
}
