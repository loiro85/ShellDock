// Genera el fondo de la ventana del .dmg (660x400 puntos) con la flecha "arrastra a Aplicaciones". Uso: swift make_dmg_background.swift salida.png [escala]
import AppKit
let out = CommandLine.arguments[1]
let scale = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1 : 1
let W = 660 * scale, H = 400 * scale
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let s = CGFloat(scale)
NSGradient(starting: NSColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1), ending: NSColor(red: 0.13, green: 0.16, blue: 0.22, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22 * s, weight: .semibold), .foregroundColor: NSColor.white]
let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13 * s), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
func centered(_ t: String, _ a: [NSAttributedString.Key: Any], y: CGFloat) {
    let str = NSAttributedString(string: t, attributes: a)
    str.draw(at: NSPoint(x: (CGFloat(W) - str.size().width) / 2, y: y * s))
}
centered("Drag ShellDock to Applications", title, y: 320)
centered("to install it", sub, y: 296)
// flecha entre los dos iconos (iconos en x=170 y x=490, y=200 desde arriba)
let green = NSColor(red: 0.25, green: 0.73, blue: 0.31, alpha: 1)
green.setStroke(); green.setFill()
let y = (400 - 200) * s
let line = NSBezierPath(); line.lineWidth = 6 * s; line.lineCapStyle = .round
line.move(to: NSPoint(x: 250 * s, y: y)); line.line(to: NSPoint(x: 400 * s, y: y)); line.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 420 * s, y: y)); head.line(to: NSPoint(x: 392 * s, y: y + 20 * s)); head.line(to: NSPoint(x: 392 * s, y: y - 20 * s)); head.close(); head.fill()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
