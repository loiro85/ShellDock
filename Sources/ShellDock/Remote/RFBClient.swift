import Foundation
import CommonCrypto
import Darwin
import CoreGraphics

/// Cliente VNC (protocolo RFB 3.3/3.7/3.8): seguridad None y VNC Auth (DES), codificaciones Raw, CopyRect, Hextile y DesktopSize.
final class RFBClient: @unchecked Sendable {
    enum Event { case connected(Int, Int, String), updated, resized(Int, Int), bell, cutText(String), closed(String?) }
    enum RFBError: LocalizedError {
        case needsPassword, connection(String), protocolError(String), authFailed(String)
        var errorDescription: String? {
            switch self {
            case .needsPassword: return tr("El servidor VNC pide contraseña")
            case .connection(let m): return tr("No se pudo conectar: %@", "\(m)")
            case .protocolError(let m): return "Error de protocolo VNC: \(m)"
            case .authFailed(let m): return tr("Autenticación VNC rechazada%@", "\(m.isEmpty ? "" : ": \(m)")")
            }
        }
    }

    private var fd: Int32 = -1
    private let lock = NSLock()
    private(set) var width = 0
    private(set) var height = 0
    private(set) var name = ""
    private var pixels = [UInt8]()           // BGRA
    var onEvent: (@Sendable (Event) -> Void)?
    private var closed = false

    // MARK: conexión

    func connect(host: String, port: Int, password: String?) throws {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { throw RFBError.connection("host desconocido") }
        defer { freeaddrinfo(res) }
        var cur: UnsafeMutablePointer<addrinfo>? = first
        var sock: Int32 = -1
        while let ai = cur {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                var tv = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { sock = s; break }
                Darwin.close(s)
            }
            cur = ai.pointee.ai_next
        }
        guard sock >= 0 else { throw RFBError.connection(String(cString: strerror(errno))) }
        var tv0 = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv0, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = sock
        do { try handshake(password: password) } catch { shutdown(); throw error }
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "rfb-reader"
        t.start()
        requestUpdate(incremental: false)
    }

    private func handshake(password: String?) throws {
        let ver = try read(12)
        guard String(decoding: ver, as: UTF8.self).hasPrefix("RFB ") else { throw RFBError.protocolError("no es un servidor VNC") }
        let minor = Int(String(decoding: ver[8..<11], as: UTF8.self)) ?? 3
        let use = minor >= 8 ? "RFB 003.008\n" : (minor >= 7 ? "RFB 003.007\n" : "RFB 003.003\n")
        try write(Array(use.utf8))
        var secType: UInt8
        if minor >= 7 {
            let n = Int(try read(1)[0])
            if n == 0 { throw RFBError.authFailed(try readReason()) }
            let types = try read(n)
            secType = types.contains(1) ? 1 : (types.contains(2) ? 2 : 0)
            guard secType != 0 else { throw RFBError.protocolError("seguridad no soportada: \(types)") }
            try write([secType])
        } else {
            let t = try read(4)
            secType = UInt8(t[3])
            if t[0] == 0 && t[1] == 0 && t[2] == 0 && secType == 0 { throw RFBError.authFailed(try readReason()) }
        }
        if secType == 2 {
            guard let pw = password else { throw RFBError.needsPassword }
            try write(Self.vncAuthResponse(challenge: try read(16), password: pw))
        }
        if secType == 2 || minor >= 8 {
            let r = try read(4)
            if r != [0, 0, 0, 0] { throw RFBError.authFailed(minor >= 8 ? (try? readReason()) ?? "" : "") }
        }
        try write([1])              // ClientInit: compartir escritorio
        let si = try read(24)
        width = Int(si[0]) << 8 | Int(si[1])
        height = Int(si[2]) << 8 | Int(si[3])
        let nameLen = Int(si[20]) << 24 | Int(si[21]) << 16 | Int(si[22]) << 8 | Int(si[23])
        name = String(decoding: try read(min(nameLen, 4096)), as: UTF8.self)
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        // formato de píxel: 32 bpp, color verdadero, little-endian, R<<16 G<<8 B
        try write([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        // codificaciones: Hextile, CopyRect, Raw, DesktopSize
        var enc: [UInt8] = [2, 0, 0, 4]
        for e: Int32 in [5, 1, 0, -223] { enc += be32(UInt32(bitPattern: e)) }
        try write(enc)
        onEvent?(.connected(width, height, name))
    }

    private func readReason() throws -> String {
        let l = try read(4)
        let n = Int(l[0]) << 24 | Int(l[1]) << 16 | Int(l[2]) << 8 | Int(l[3])
        return String(decoding: try read(min(n, 4096)), as: UTF8.self)
    }

    /// Respuesta VNC Auth: DES-ECB del desafío con la contraseña (8 bytes, cada byte con los bits invertidos).
    static func vncAuthResponse(challenge: [UInt8], password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in password.utf8.prefix(8).enumerated() {
            var r: UInt8 = 0
            for bit in 0..<8 where b & (1 << bit) != 0 { r |= 1 << (7 - bit) }
            key[i] = r
        }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode), key, 8, nil, challenge, 16, &out, 16, &moved)
        return out
    }

    // MARK: E/S

    private func read(_ n: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, n - got) }
            if r <= 0 { throw RFBError.connection(r == 0 ? tr("conexión cerrada") : String(cString: strerror(errno))) }
            got += r
        }
        return buf
    }

    private func write(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let r = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if r <= 0 { throw RFBError.connection("escritura fallida") }
            off += r
        }
    }

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    // MARK: entrada del usuario

    func requestUpdate(incremental: Bool) {
        try? write([3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(width) + be16(height))
    }

    func sendPointer(x: Int, y: Int, buttons: Int) {
        try? write([5, UInt8(buttons & 0xFF)] + be16(max(0, min(x, width - 1))) + be16(max(0, min(y, height - 1))))
    }

    func sendKey(_ keysym: UInt32, down: Bool) {
        try? write([4, down ? 1 : 0, 0, 0] + be32(keysym))
    }

    func sendClipboard(_ text: String) {
        let d = Array(text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data())
        try? write([6, 0, 0, 0] + be32(UInt32(d.count)) + d)
    }

    func close() { shutdown() }

    private func shutdown() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
    }

    // MARK: lectura de mensajes

    private func readLoop() {
        do {
            while true {
                let t = try read(1)[0]
                switch t {
                case 0: try framebufferUpdate()
                case 1:     // SetColourMapEntries (se ignora)
                    let h = try read(5)
                    _ = try read((Int(h[3]) << 8 | Int(h[4])) * 6)
                case 2: onEvent?(.bell)
                case 3:
                    let h = try read(7)
                    let n = Int(h[3]) << 24 | Int(h[4]) << 16 | Int(h[5]) << 8 | Int(h[6])
                    let d = try read(min(n, 1 << 20))
                    onEvent?(.cutText(String(decoding: d, as: UTF8.self)))
                default: throw RFBError.protocolError("mensaje desconocido \(t)")
                }
            }
        } catch {
            lock.lock(); let was = closed; lock.unlock()
            shutdown()
            onEvent?(.closed(was ? nil : error.localizedDescription))
        }
    }

    private func framebufferUpdate() throws {
        let h = try read(3)
        let rects = Int(h[1]) << 8 | Int(h[2])
        for _ in 0..<rects {
            let r = try read(12)
            let x = Int(r[0]) << 8 | Int(r[1]), y = Int(r[2]) << 8 | Int(r[3])
            let w = Int(r[4]) << 8 | Int(r[5]), hh = Int(r[6]) << 8 | Int(r[7])
            let enc = Int32(bitPattern: UInt32(r[8]) << 24 | UInt32(r[9]) << 16 | UInt32(r[10]) << 8 | UInt32(r[11]))
            switch enc {
            case 0:
                let data = try read(w * hh * 4)
                lock.lock()
                for row in 0..<hh { copyRow(from: data, srcOffset: row * w * 4, toX: x, y: y + row, count: w) }
                lock.unlock()
            case 1:
                let s = try read(4)
                let sx = Int(s[0]) << 8 | Int(s[1]), sy = Int(s[2]) << 8 | Int(s[3])
                lock.lock()
                var tmp = [UInt8](repeating: 0, count: w * hh * 4)
                for row in 0..<hh where sy + row < height && sx + w <= width {
                    let so = ((sy + row) * width + sx) * 4
                    for i in 0..<(w * 4) { tmp[row * w * 4 + i] = pixels[so + i] }
                }
                for row in 0..<hh where y + row < height && x + w <= width {
                    let d = ((y + row) * width + x) * 4
                    for i in 0..<(w * 4) { pixels[d + i] = tmp[row * w * 4 + i] }
                }
                lock.unlock()
            case 5: try hextile(x: x, y: y, w: w, h: hh)
            case -223:
                lock.lock()
                width = w; height = hh
                pixels = [UInt8](repeating: 0, count: w * hh * 4)
                lock.unlock()
                onEvent?(.resized(w, hh))
            default: throw RFBError.protocolError("codificación \(enc) no soportada")
            }
        }
        onEvent?(.updated)
        requestUpdate(incremental: true)
    }

    /// Debe llamarse con el cerrojo tomado.
    private func copyRow(from data: [UInt8], srcOffset: Int, toX x: Int, y: Int, count: Int) {
        guard y >= 0, y < height, x >= 0, x + count <= width else { return }
        let d = (y * width + x) * 4
        for i in 0..<(count * 4) { pixels[d + i] = data[srcOffset + i] }
    }

    private func fill(x: Int, y: Int, w: Int, h: Int, color: [UInt8]) {
        guard w > 0, h > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        for row in 0..<h where y + row >= 0 && y + row < height {
            for col in 0..<w where x + col >= 0 && x + col < width {
                let d = ((y + row) * width + x + col) * 4
                pixels[d] = color[0]; pixels[d + 1] = color[1]; pixels[d + 2] = color[2]; pixels[d + 3] = 255
            }
        }
    }

    private func hextile(x: Int, y: Int, w: Int, h: Int) throws {
        var bg: [UInt8] = [0, 0, 0, 255]
        var fg: [UInt8] = [255, 255, 255, 255]
        var ty = 0
        while ty < h {
            var tx = 0
            let th = min(16, h - ty)
            while tx < w {
                let tw = min(16, w - tx)
                let sub = try read(1)[0]
                if sub & 1 != 0 {
                    let data = try read(tw * th * 4)
                    lock.lock()
                    for row in 0..<th { copyRow(from: data, srcOffset: row * tw * 4, toX: x + tx, y: y + ty + row, count: tw) }
                    lock.unlock()
                } else {
                    if sub & 2 != 0 { bg = Array(try read(4)); bg[3] = 255 }
                    if sub & 4 != 0 { fg = Array(try read(4)); fg[3] = 255 }
                    fill(x: x + tx, y: y + ty, w: tw, h: th, color: bg)
                    if sub & 8 != 0 {
                        let n = Int(try read(1)[0])
                        for _ in 0..<n {
                            var c = fg
                            if sub & 16 != 0 { c = Array(try read(4)); c[3] = 255 }
                            let xy = try read(2)
                            let (sx, sy) = (Int(xy[0] >> 4), Int(xy[0] & 15))
                            let (sw, sh) = (Int(xy[1] >> 4) + 1, Int(xy[1] & 15) + 1)
                            fill(x: x + tx + sx, y: y + ty + sy, w: sw, h: sh, color: c)
                        }
                    }
                }
                tx += 16
            }
            ty += 16
        }
    }

    // MARK: imagen

    func snapshotPixels() -> (Int, Int, [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        return (width, height, pixels)
    }

    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        lock.lock(); defer { lock.unlock() }
        let o = (y * width + x) * 4
        return (pixels[o + 2], pixels[o + 1], pixels[o])
    }

    func makeImage() -> CGImage? {
        let (w, h, px) = snapshotPixels()
        guard w > 0, h > 0, let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
