import AppKit
import Metal

/// Color RGBA en sRGB (0...1), codificable en el proyecto.
struct RGBA: Codable, Equatable, Hashable {
    var r: Float
    var g: Float
    var b: Float
    var a: Float

    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }

    init(r: Float, g: Float, b: Float, a: Float) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .white
        self.init(r: Float(c.redComponent), g: Float(c.greenComponent), b: Float(c.blueComponent), a: Float(c.alphaComponent))
    }
}

/// Movimiento del texto. Los valores internos son estables (se guardan en el proyecto); las etiquetas son solo para mostrar.
enum TextMode: String, Codable, CaseIterable, Identifiable {
    case still, scrollLeft, scrollRight, scrollUp, scrollDown, blink, pulse, typewriter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .still: return "Fijo"
        case .scrollLeft: return "Desplazar ←"
        case .scrollRight: return "Desplazar →"
        case .scrollUp: return "Desplazar ↑ (créditos)"
        case .scrollDown: return "Desplazar ↓"
        case .blink: return "Parpadeo"
        case .pulse: return "Pulso"
        case .typewriter: return "Máquina de escribir"
        }
    }

    var isScroll: Bool { self == .scrollLeft || self == .scrollRight || self == .scrollUp || self == .scrollDown }
    var isHorizontal: Bool { self == .scrollLeft || self == .scrollRight }

    /// Qué significa la velocidad en cada modo (para el panel).
    var speedLabel: String {
        switch self {
        case .still: return ""
        case .scrollLeft, .scrollRight, .scrollUp, .scrollDown: return "Cuadros por segundo"
        case .blink, .pulse: return "Veces por segundo"
        case .typewriter: return "Letras por segundo"
        }
    }

    var speedRange: ClosedRange<Double> {
        switch self {
        case .still: return 0...1
        case .scrollLeft, .scrollRight, .scrollUp, .scrollDown: return 0.02...1
        case .blink, .pulse: return 0.1...4
        case .typewriter: return 1...40
        }
    }

    var defaultSpeed: Float {
        switch self {
        case .still: return 0
        case .scrollLeft, .scrollRight, .scrollUp, .scrollDown: return 0.2
        case .blink: return 1
        case .pulse: return 0.5
        case .typewriter: return 8
        }
    }
}

enum TextAlign: String, Codable, CaseIterable {
    case left, center, right

    var ns: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

/// Un texto para proyectar: contenido, tipografía, color, fondo y movimiento.
struct TextSpec: Codable, Equatable, Hashable {
    var text = "Hola"
    var fontName = "Helvetica Neue"
    var bold = true
    var italic = false
    var align: TextAlign = .center
    /// Ajusta el tamaño de letra al cuadro (en los modos de desplazamiento, a un tamaño legible).
    var autoFit = true
    /// Tamaño de letra como % de la altura del cuadro (cuando no es automático).
    var sizePercent: Float = 20
    /// Interlineado extra, como fracción del tamaño de letra.
    var lineSpacing: Float = 0
    var color = RGBA.white
    /// Fondo del cuadro: con transparencia total (alfa 0) el texto flota sobre las otras capas.
    var background = RGBA.clear
    /// Grosor del contorno, como % del tamaño de letra (0 = sin contorno).
    var outline: Float = 0
    var outlineColor = RGBA.black
    /// Proporción (ancho/alto) del cuadro del texto; la superficie toma esta proporción.
    var aspect: Float = 16.0 / 9
    var mode: TextMode = .still
    /// Velocidad del movimiento (su unidad depende del modo).
    var speed: Float = 0.2

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextSpec()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? d.bold
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? d.italic
        align = try c.decodeIfPresent(TextAlign.self, forKey: .align) ?? d.align
        autoFit = try c.decodeIfPresent(Bool.self, forKey: .autoFit) ?? d.autoFit
        sizePercent = try c.decodeIfPresent(Float.self, forKey: .sizePercent) ?? d.sizePercent
        lineSpacing = try c.decodeIfPresent(Float.self, forKey: .lineSpacing) ?? d.lineSpacing
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        background = try c.decodeIfPresent(RGBA.self, forKey: .background) ?? d.background
        outline = try c.decodeIfPresent(Float.self, forKey: .outline) ?? d.outline
        outlineColor = try c.decodeIfPresent(RGBA.self, forKey: .outlineColor) ?? d.outlineColor
        aspect = try c.decodeIfPresent(Float.self, forKey: .aspect) ?? d.aspect
        mode = try c.decodeIfPresent(TextMode.self, forKey: .mode) ?? d.mode
        speed = try c.decodeIfPresent(Float.self, forKey: .speed) ?? d.speed
    }

    /// Cantidad de letras (para la máquina de escribir).
    var length: Int { max(text.count, 1) }

    /// Texto corto para mostrar en listas.
    var summary: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 26 ? String(line.prefix(26)) + "…" : (line.isEmpty ? "(vacío)" : line)
    }
}

/// Dibuja un `TextSpec` en una textura Metal (con alfa «recto», sin premultiplicar, como las imágenes).
enum TextRenderer {
    struct Output {
        let texture: MTLTexture
        /// Tamaño de la textura, en píxeles.
        let width: Int
        let height: Int
        /// Tamaño de la ventana visible (el cuadro), en píxeles. Si es menor que la textura, el texto se desplaza.
        let boxW: Int
        let boxH: Int
    }

    private static let maxSide = 8192
    private static var sizeCache: [String: CGFloat] = [:]

    // MARK: Fuentes

    static var availableFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func font(_ spec: TextSpec, _ size: CGFloat) -> NSFont {
        var traits: NSFontTraitMask = []
        if spec.bold { traits.insert(.boldFontMask) }
        if spec.italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: spec.fontName, traits: traits, weight: 5, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: spec.bold ? .bold : .regular)
    }

    private static func attributed(_ spec: TextSpec, _ string: String, _ size: CGFloat, visible: Int?) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = spec.align.ns
        para.lineSpacing = CGFloat(spec.lineSpacing) * size
        para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(spec, size),
            .foregroundColor: spec.color.nsColor,
            .paragraphStyle: para,
        ]
        if spec.outline > 0 {
            attrs[.strokeWidth] = -CGFloat(spec.outline)   // negativo = relleno + contorno
            attrs[.strokeColor] = spec.outlineColor.nsColor
        }
        let s = NSMutableAttributedString(string: string, attributes: attrs)
        // Máquina de escribir: se dibuja todo el texto (para que el diseño no se mueva) pero lo que falta, transparente.
        if let n = visible, n < string.count {
            let shown = (String(string.prefix(n)) as NSString).length
            let range = NSRange(location: shown, length: s.length - shown)
            s.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            s.addAttribute(.strokeColor, value: NSColor.clear, range: range)
        }
        return s
    }

    private static func measure(_ spec: TextSpec, _ string: String, _ size: CGFloat, width: CGFloat) -> CGSize {
        let r = attributed(spec, string, size, visible: nil)
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    // MARK: Render

    static func render(_ spec: TextSpec, visible: Int?, device: MTLDevice, queue: MTLCommandQueue) -> Output? {
        let aspect = CGFloat(min(max(spec.aspect, 0.1), 10))
        let base: CGFloat = 2048
        let boxW = Int((aspect >= 1 ? base : base * aspect).rounded())
        let boxH = Int((aspect >= 1 ? base / aspect : base).rounded())
        let pad = CGFloat(min(boxW, boxH)) * 0.04
        let string = spec.text.isEmpty ? " " : spec.text

        var texW = boxW, texH = boxH
        enum Layout { case wrapped(size: CGFloat, height: CGFloat), line(size: CGFloat, width: CGFloat, height: CGFloat), column(size: CGFloat, height: CGFloat) }
        let layout: Layout

        switch spec.mode {
        case .scrollLeft, .scrollRight:
            // Una sola línea (los saltos de línea pasan a ser espacios); delante lleva un espacio en blanco del ancho del cuadro.
            let line = string.replacingOccurrences(of: "\n", with: "   ")
            var size = spec.autoFit ? CGFloat(boxH) * 0.62 : CGFloat(spec.sizePercent) / 100 * CGFloat(boxH)
            var m = attributed(spec, line, size, visible: nil).size()
            let room = CGFloat(maxSide - boxW)
            if m.width > room { size *= room / m.width * 0.98; m = attributed(spec, line, size, visible: nil).size() }
            texW = boxW + Int(ceil(m.width)) + Int(size * 0.5)
            layout = .line(size: size, width: ceil(m.width), height: ceil(m.height))

        case .scrollUp, .scrollDown:
            // Varias líneas en el ancho del cuadro; delante lleva un espacio en blanco de la altura del cuadro (créditos).
            var size = spec.autoFit ? CGFloat(boxH) * 0.14 : CGFloat(spec.sizePercent) / 100 * CGFloat(boxH)
            let w = CGFloat(boxW) - 2 * pad
            var m = measure(spec, string, size, width: w)
            let room = CGFloat(maxSide - boxH)
            if m.height > room { size *= room / m.height * 0.95; m = measure(spec, string, size, width: w) }
            texH = boxH + Int(m.height) + Int(size)
            layout = .column(size: size, height: m.height)

        default:
            let rect = CGSize(width: CGFloat(boxW) - 2 * pad, height: CGFloat(boxH) - 2 * pad)
            let key = "\(spec.text)|\(spec.fontName)|\(spec.bold)|\(spec.italic)|\(spec.aspect)|\(spec.autoFit)|\(spec.sizePercent)|\(spec.lineSpacing)|\(spec.outline)"
            var size: CGFloat
            if !spec.autoFit {
                size = CGFloat(spec.sizePercent) / 100 * CGFloat(boxH)
            } else if let cached = sizeCache[key] {
                size = cached
            } else {
                var lo: CGFloat = 4, hi = rect.height
                for _ in 0..<14 {
                    let mid = (lo + hi) / 2
                    if measure(spec, string, mid, width: rect.width).height <= rect.height { lo = mid } else { hi = mid }
                }
                size = lo
                // Que ni siquiera la palabra más larga se corte a la mitad.
                let widest = string.split(whereSeparator: \.isWhitespace)
                    .map { attributed(spec, String($0), size, visible: nil).size().width }.max() ?? 0
                if widest > rect.width { size *= rect.width / widest }
                if sizeCache.count > 300 { sizeCache.removeAll() }
                sizeCache[key] = size
            }
            layout = .wrapped(size: size, height: measure(spec, string, size, width: rect.width).height)
        }

        // Bitmap RGBA con alfa premultiplicado; después se pasa a alfa recto.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: texW, height: texH, bitsPerComponent: 8, bytesPerRow: texW * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.setFillColor(spec.background.nsColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: texW, height: texH))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        switch layout {
        case .wrapped(let size, let h):
            let rect = CGRect(x: pad, y: (CGFloat(texH) - h) / 2, width: CGFloat(boxW) - 2 * pad, height: h)
            attributed(spec, string, size, visible: visible).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .line(let size, let w, let h):
            let line = string.replacingOccurrences(of: "\n", with: "   ")
            let rect = CGRect(x: CGFloat(boxW), y: (CGFloat(texH) - h) / 2, width: w + size, height: h)
            attributed(spec, line, size, visible: nil).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .column(let size, let h):
            // El inicio del texto queda debajo del espacio en blanco (que ocupa la parte de arriba de la textura).
            let rect = CGRect(x: pad, y: 0, width: CGFloat(boxW) - 2 * pad, height: h)
            attributed(spec, string, size, visible: nil).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        NSGraphicsContext.restoreGraphicsState()

        let p = data.bindMemory(to: UInt8.self, capacity: texW * texH * 4)
        for i in stride(from: 0, to: texW * texH * 4, by: 4) {
            let a = Int(p[i + 3])
            if a > 0 && a < 255 {
                p[i] = UInt8(min(255, Int(p[i]) * 255 / a))
                p[i + 1] = UInt8(min(255, Int(p[i + 1]) * 255 / a))
                p[i + 2] = UInt8(min(255, Int(p[i + 2]) * 255 / a))
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: texW, height: texH, mipmapped: true)
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, texW, texH), mipmapLevel: 0, withBytes: data, bytesPerRow: texW * 4)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return Output(texture: tex, width: texW, height: texH, boxW: boxW, boxH: boxH)
    }
}
