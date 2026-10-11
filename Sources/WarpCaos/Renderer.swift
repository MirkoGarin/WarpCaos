import MetalKit

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
}

private struct MaskInfo {
    var start: UInt32
    var count: UInt32
    var feather: Float
    var flags: UInt32
}

/// Recursos de GPU/medios de una superficie.
private final class Resources {
    var source: Source?
    var texture: MTLTexture?
    var video: VideoSource?
    var sizeReported = false
    var wasPlaying = true
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
            syncSource(r, s)
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
            guard let r = resources[s.id], let tex = r.texture,
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
            let cm = s.contentMatrix, sm = s.shapeMatrix
            var u = FragUniform(viewport: viewport, origin: origin, opacity: s.opacity, maskCount: UInt32(maskCount),
                                shape: s.shape.shaderID, shapeFeather: s.shapeFeather,
                                uvM0: cm.0, uvM1: cm.1, shM0: sm.0, shM1: sm.1)

            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentTexture(tex, index: 0)
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

    // MARK: Fuente de contenido

    private func syncSource(_ r: Resources, _ s: SurfaceModel) {
        if r.source != s.source { loadSource(r, s) }
        guard let video = r.video else { return }

        if video.update(), let t = video.texture {
            r.texture = t
            if !r.sizeReported {
                r.sizeReported = true
                state.contentLoaded(id: s.id, aspect: Float(t.width) / Float(t.height), isVideo: true)
            }
        }
        if s.playing != r.wasPlaying {
            r.wasPlaying = s.playing
            s.playing ? video.player.play() : video.player.pause()
        }
        if video.player.isMuted != s.muted { video.player.isMuted = s.muted }
    }

    private func loadSource(_ r: Resources, _ s: SurfaceModel) {
        r.source = s.source
        r.video = nil
        r.sizeReported = false

        switch s.source {
        case .pattern(let p):
            r.texture = Generators.texture(device: device, pattern: p)
            state.contentLoaded(id: s.id, aspect: 1, isVideo: false)

        case .file(let url):
            switch MediaKind.of(url) {
            case .image:
                do {
                    let t = try textureLoader.newTexture(URL: url, options: [
                        .SRGB: false,
                        .origin: MTKTextureLoader.Origin.topLeft,
                        .generateMipmaps: true,
                    ])
                    r.texture = t
                    state.contentLoaded(id: s.id, aspect: Float(t.width) / Float(t.height), isVideo: false)
                } catch {
                    state.contentFailed(id: s.id, message: "No se pudo abrir la imagen: \(error.localizedDescription)")
                }
            case .video:
                guard let v = VideoSource(url: url, device: device) else {
                    state.contentFailed(id: s.id, message: "No se pudo abrir el video")
                    return
                }
                r.video = v
                r.texture = nil
                r.wasPlaying = s.playing
                v.player.isMuted = s.muted
                if s.playing { v.player.play() }
                state.contentLoaded(id: s.id, aspect: s.contentAspect, isVideo: true)
            case nil:
                state.contentFailed(id: s.id, message: "Formato no soportado")
            }
        }
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
