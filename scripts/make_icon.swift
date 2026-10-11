// Genera Resources/AppIcon.icns: malla de warp deformada con nodos, sobre fondo oscuro.
// Uso: swift scripts/make_icon.swift
import AppKit

let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

// Cuerpo del ícono (plantilla macOS: 824 pt centrados en 1024).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.07, green: 0.08, blue: 0.20, alpha: 1),
    CGColor(red: 0.27, green: 0.08, blue: 0.36, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.35, green: 0.75, blue: 1, alpha: 0.35),
    CGColor(red: 0.35, green: 0.75, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 540), endRadius: 460, options: [])

// Malla deformada: abultada y con un giro suave.
func warp(_ u: Double, _ v: Double) -> CGPoint {
    var dx = u - 0.5, dy = v - 0.5
    let r = (dx * dx + dy * dy).squareRoot()
    let k = 1 + 0.9 * r * r                       // abultado tipo barril
    let a = 0.55 * max(0, 0.75 - r)               // giro, más fuerte al centro
    (dx, dy) = ((dx * cos(a) - dy * sin(a)) * k, (dx * sin(a) + dy * cos(a)) * k)
    let area = CGRect(x: 205, y: 205, width: 614, height: 614)
    return CGPoint(x: area.minX + (0.5 + dx * 0.78) * area.width, y: area.minY + (0.5 + dy * 0.78) * area.height)
}

let n = 6, steps = 48
ctx.setLineCap(.round); ctx.setLineJoin(.round)
func stroke(_ pts: [CGPoint], _ color: CGColor, _ w: CGFloat) {
    ctx.setStrokeColor(color); ctx.setLineWidth(w)
    ctx.beginPath(); ctx.addLines(between: pts); ctx.strokePath()
}
for i in 0...n {
    let t = Double(i) / Double(n)
    let h = (0...steps).map { warp(Double($0) / Double(steps), t) }
    let v = (0...steps).map { warp(t, Double($0) / Double(steps)) }
    stroke(h, CGColor(red: 0.30, green: 0.90, blue: 1.0, alpha: 0.95), 11)
    stroke(v, CGColor(red: 1.00, green: 0.38, blue: 0.82, alpha: 0.95), 11)
}
// Nodos.
for i in 0...n {
    for j in 0...n {
        let p = warp(Double(i) / Double(n), Double(j) / Double(n))
        let hot = (i == 2 && j == 3)
        let s: CGFloat = hot ? 40 : 28
        ctx.setFillColor(hot ? CGColor(red: 1, green: 0.58, blue: 0.1, alpha: 1) : CGColor(gray: 1, alpha: 0.95))
        ctx.addPath(CGPath(roundedRect: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s),
                           cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.fillPath()
    }
}
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()

let out = "Resources/AppIcon-1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("OK \(out)")
