import AppKit
import SwiftUI

/// Vista que dibuja el framebuffer remoto y reenvía ratón y teclado.
final class VNCView: NSView {
    var client: RFBClient?
    private var buttons = 0

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let img = client?.makeImage(), let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = fitRect(w: CGFloat(img.width), h: CGFloat(img.height))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    private func fitRect(w: CGFloat, h: CGFloat) -> CGRect {
        let s = min(bounds.width / w, bounds.height / h)
        let rw = w * s, rh = h * s
        return CGRect(x: (bounds.width - rw) / 2, y: (bounds.height - rh) / 2, width: rw, height: rh)
    }

    private func remotePoint(_ e: NSEvent) -> (Int, Int)? {
        guard let c = client, c.width > 0 else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        let r = fitRect(w: CGFloat(c.width), h: CGFloat(c.height))
        return (Int((p.x - r.minX) / r.width * CGFloat(c.width)), Int((p.y - r.minY) / r.height * CGFloat(c.height)))
    }

    private func pointer(_ e: NSEvent) {
        if let (x, y) = remotePoint(e) { client?.sendPointer(x: x, y: y, buttons: buttons) }
    }

    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; pointer(e) }
    override func mouseUp(with e: NSEvent) { buttons &= ~1; pointer(e) }
    override func rightMouseDown(with e: NSEvent) { buttons |= 4; pointer(e) }
    override func rightMouseUp(with e: NSEvent) { buttons &= ~4; pointer(e) }
    override func otherMouseDown(with e: NSEvent) { buttons |= 2; pointer(e) }
    override func otherMouseUp(with e: NSEvent) { buttons &= ~2; pointer(e) }
    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func scrollWheel(with e: NSEvent) {
        guard let (x, y) = remotePoint(e), e.scrollingDeltaY != 0 else { return }
        let b = e.scrollingDeltaY > 0 ? 8 : 16
        client?.sendPointer(x: x, y: y, buttons: buttons | b)
        client?.sendPointer(x: x, y: y, buttons: buttons)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func keyDown(with e: NSEvent) { key(e, down: true) }
    override func keyUp(with e: NSEvent) { key(e, down: false) }
    override func performKeyEquivalent(with e: NSEvent) -> Bool { false }

    private func key(_ e: NSEvent, down: Bool) {
        guard let sym = Self.keysym(for: e) else { return }
        client?.sendKey(sym, down: down)
    }

    static func keysym(for e: NSEvent) -> UInt32? {
        let special: [UInt16: UInt32] = [
            36: 0xFF0D, 76: 0xFF0D, 48: 0xFF09, 51: 0xFF08, 53: 0xFF1B, 117: 0xFFFF, 123: 0xFF51, 124: 0xFF53,
            125: 0xFF54, 126: 0xFF52, 115: 0xFF50, 119: 0xFF57, 116: 0xFF55, 121: 0xFF56, 114: 0xFF63,
            122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2, 97: 0xFFC3, 98: 0xFFC4, 100: 0xFFC5,
            101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9]
        if let s = special[e.keyCode] { return s }
        guard let ch = e.characters?.unicodeScalars.first else { return nil }
        let v = ch.value
        if v < 0x20 { return v + 0x60 }                  // control: la letra base
        if v >= 0xF700 { return nil }
        return v < 0x100 ? v : 0x01000000 + v
    }
}

@MainActor
final class VNCTab: TerminalTab {
    let view = VNCView()
    private let client = RFBClient()
    private let host: String
    private let port: Int
    private var password: String?
    private var closedByUser = false

    init(session: Session) {
        host = session.host
        port = session.port > 0 ? session.port : 5900
        password = Keychain.get(account: session.id.uuidString)
        super.init(title: session.name, kind: .vnc, session: session)
        view.client = client
    }

    override var content: NSView { view }
    override var canReconnect: Bool { true }
    override func focus() { content.window?.makeFirstResponder(view) }

    override func start() {
        status = .connecting
        client.onEvent = { [weak self] ev in
            DispatchQueue.main.async { self?.handle(ev) }
        }
        let (h, p, pw) = (host, port, password)
        let c = client
        DispatchQueue.global().async { [weak self] in
            do { try c.connect(host: h, port: p, password: pw) }
            catch { DispatchQueue.main.async { self?.status = .failed(error.localizedDescription) } }
        }
    }

    private func handle(_ ev: RFBClient.Event) {
        switch ev {
        case .connected: status = .connected; view.needsDisplay = true
        case .updated, .resized: view.needsDisplay = true
        case .bell: NSSound.beep()
        case .cutText(let t): NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
        case .closed(let m): if !closedByUser { status = m.map { .failed($0) } ?? .closed }
        }
    }

    override func sendText(_ s: String) {
        for u in s.unicodeScalars {
            let sym = u.value < 0x100 ? u.value : 0x01000000 + u.value
            client.sendKey(sym, down: true); client.sendKey(sym, down: false)
        }
    }

    override func reconnect() { close(); closedByUser = false; start() }
    override func close() { closedByUser = true; client.close() }
}
