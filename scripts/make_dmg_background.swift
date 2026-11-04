// Genera el fondo de la ventana del .dmg (660x400 puntos) con la flecha "arrastra a Aplicaciones". Uso: swift make_dmg_background.swift salida.png [escala]
import AppKit
let out = CommandLine.arguments[1]
let scale = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1 : 1
let W = 660 * scale, H = 400 * scale
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let s = CGFloat(scale)
NSColor(red: 0.937, green: 0.933, blue: 0.914, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
let serif = NSFont.systemFont(ofSize: 40 * s, weight: .bold).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 40 * s) } ?? NSFont.boldSystemFont(ofSize: 40 * s)
let title: [NSAttributedString.Key: Any] = [.font: serif, .foregroundColor: NSColor(white: 0.08, alpha: 1), .kern: -1.0 * s]
let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17 * s), .foregroundColor: NSColor(white: 0.42, alpha: 1)]
func centered(_ t: String, _ a: [NSAttributedString.Key: Any], y: CGFloat) {
    let str = NSAttributedString(string: t, attributes: a)
    str.draw(at: NSPoint(x: (CGFloat(W) - str.size().width) / 2, y: y * s))
}
centered("Install ShellDock", title, y: 296)
centered("Drag to Applications", sub, y: 262)
// flecha fina entre los dos iconos (iconos en x=170 y x=490; y=210 desde arriba)
NSColor(white: 0.5, alpha: 1).setStroke()
let y = (400 - 210) * s
let line = NSBezierPath(); line.lineWidth = 1.6 * s; line.lineCapStyle = .round; line.lineJoinStyle = .round
line.move(to: NSPoint(x: 268 * s, y: y)); line.line(to: NSPoint(x: 392 * s, y: y))
line.move(to: NSPoint(x: 380 * s, y: y + 8 * s)); line.line(to: NSPoint(x: 392 * s, y: y)); line.line(to: NSPoint(x: 380 * s, y: y - 8 * s))
line.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
