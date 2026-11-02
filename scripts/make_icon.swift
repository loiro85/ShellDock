import AppKit

// Genera scripts/AppIcon.icns: ventana de shell negra con barra de título y prompt luminoso.
func render(_ s: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = CGFloat(s) / 1024
    func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }
    // ventana (con margen para la sombra, como los iconos de macOS)
    let win = NSRect(x: 100 * u, y: 110 * u, width: 824 * u, height: 804 * u)
    let path = NSBezierPath(roundedRect: win, xRadius: 150 * u, yRadius: 150 * u)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = c(0x000000, 0.5); sh.shadowBlurRadius = 40 * u; sh.shadowOffset = NSSize(width: 0, height: -18 * u)
    sh.set(); c(0x0B0D12).setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [c(0x161A23), c(0x05060A)])!.draw(in: path, angle: -90)
    // barra de título
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let bar = NSRect(x: win.minX, y: win.maxY - 130 * u, width: win.width, height: 130 * u)
    NSGradient(colors: [c(0x2B303C), c(0x1D212B)])!.draw(in: bar, angle: -90)
    c(0xFFFFFF, 0.08).setFill(); NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 3 * u).fill()
    for (i, col) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        c(UInt32(col)).setFill()
        let r = 22 * u
        NSBezierPath(ovalIn: NSRect(x: win.minX + (70 + CGFloat(i) * 68) * u - r, y: bar.midY - r, width: 2 * r, height: 2 * r)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    // borde luminoso
    c(0x7C8CFF, 0.55).setStroke(); path.lineWidth = 6 * u; path.stroke()
    // prompt  ❯_
    let green = c(0x4DF0A0), cyan = c(0x56D4FF)
    func glow(_ col: NSColor, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let g = NSShadow(); g.shadowColor = col.withAlphaComponent(0.9); g.shadowBlurRadius = 36 * u; g.shadowOffset = .zero
        g.set(); draw()
        NSGraphicsContext.restoreGraphicsState()
    }
    let chev = NSBezierPath()
    chev.move(to: NSPoint(x: 230 * u, y: 640 * u)); chev.line(to: NSPoint(x: 400 * u, y: 500 * u)); chev.line(to: NSPoint(x: 230 * u, y: 360 * u))
    chev.lineWidth = 72 * u; chev.lineCapStyle = .round; chev.lineJoinStyle = .round
    glow(green) { green.setStroke(); chev.stroke() }
    let us = NSBezierPath(roundedRect: NSRect(x: 470 * u, y: 340 * u, width: 280 * u, height: 62 * u), xRadius: 31 * u, yRadius: 31 * u)
    glow(cyan) { cyan.setFill(); us.fill() }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = CommandLine.arguments[1]
let set = "\(dir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
