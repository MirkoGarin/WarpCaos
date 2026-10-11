import Metal

enum Pattern: String, CaseIterable, Identifiable, Codable {
    case checkerboard = "Tablero"
    case grid = "Grilla"
    case uv = "UV (orientación)"
    case colorBars = "Barras de color"
    case white = "Blanco"
    var id: String { rawValue }
}

/// Generadores de patrones de calibración (texturas CPU).
enum Generators {
    typealias RGB = (UInt8, UInt8, UInt8)

    static func texture(device: MTLDevice, pattern: Pattern, size: Int = 1024) -> MTLTexture? {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let fn = pixelFunction(pattern, size: size)
        for y in 0..<size {
            for x in 0..<size {
                let c = fn(x, y)
                let i = (y * size + x) * 4
                pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = 255
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, size, size),
                    mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        return tex
    }

    private static func pixelFunction(_ pattern: Pattern, size: Int) -> (Int, Int) -> RGB {
        switch pattern {
        case .checkerboard:
            let cell = size / 8
            return { x, y in ((x / cell) + (y / cell)) % 2 == 0 ? (255, 255, 255) : (20, 20, 20) }

        case .grid:
            let step = size / 8, border = 8
            return { x, y in
                // Bordes de color para ver orientación: arriba rojo, derecha verde, abajo azul, izquierda amarillo.
                if y < border { return (255, 40, 40) }
                if x >= size - border { return (40, 255, 40) }
                if y >= size - border { return (60, 90, 255) }
                if x < border { return (255, 220, 40) }
                if x % step < 2 || y % step < 2 { return (210, 210, 210) }
                return (25, 25, 30)
            }

        case .uv:
            return { x, y in (UInt8(x * 255 / (size - 1)), UInt8(y * 255 / (size - 1)), 0) }

        case .colorBars:
            let bars: [RGB] = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
                               (255, 0, 255), (255, 0, 0), (0, 0, 255)]
            return { x, _ in bars[min(x * bars.count / size, bars.count - 1)] }

        case .white:
            return { _, _ in (255, 255, 255) }
        }
    }
}
