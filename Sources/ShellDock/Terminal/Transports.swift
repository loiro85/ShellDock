import Foundation
import Network
import Darwin

/// Transporte de bytes para pestañas que no usan un proceso (Telnet, TCP crudo, serie).
@MainActor
protocol ByteTransport: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onData: (([UInt8]) -> Void)? { get set }
    var onClose: ((String?) -> Void)? { get set }
    func open()
    func send(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func close()
}

// MARK: TCP crudo

@MainActor
final class TCPTransport: ByteTransport {
    var onOpen: (() -> Void)?
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?
    private var conn: NWConnection?
    private let host: String
    private let port: UInt16
    private var finished = false

    init(host: String, port: Int) {
        self.host = host
        self.port = UInt16(clamping: port)
    }

    func open() {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 23, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                switch st {
                case .ready: self.onOpen?(); self.receive()
                case .failed(let e): self.finish(e.localizedDescription)
                case .waiting(let e): self.finish(e.localizedDescription)
                case .cancelled: self.finish(nil)
                default: break
                }
            }
        }
        c.start(queue: .main)
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isDone, error in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                if let d = data, !d.isEmpty { self.onData?([UInt8](d)) }
                if isDone { self.finish(nil) }
                else if let e = error { self.finish(e.localizedDescription) }
                else { self.receive() }
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        conn?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    func resize(cols: Int, rows: Int) {}

    func close() {
        finished = true
        conn?.cancel()
        conn = nil
    }

    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        conn?.cancel()
        onClose?(error)
    }
}

// MARK: Telnet

/// Telnet sobre TCP: negociación de opciones (ECHO, SGA, TTYPE, NAWS), eliminación de secuencias IAC y CR→CRLF.
@MainActor
final class TelnetTransport: ByteTransport {
    var onOpen: (() -> Void)? { get { tcp.onOpen } set { tcp.onOpen = newValue } }
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)? { get { tcp.onClose } set { tcp.onClose = newValue } }
    private let tcp: TCPTransport
    private var parser = TelnetParser()
    private var cols = 80, rows = 24
    private var nawsEnabled = false
    private let termType: String

    init(host: String, port: Int, termType: String = "xterm-256color") {
        tcp = TCPTransport(host: host, port: port)
        self.termType = termType
        tcp.onData = { [weak self] bytes in self?.received(bytes) }
    }

    func open() { tcp.open() }
    func close() { tcp.close() }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        if nawsEnabled { sendNAWS() }
    }

    func send(_ bytes: [UInt8]) {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        for b in bytes {
            if b == 0xFF { out += [0xFF, 0xFF] }
            else if b == 0x0D { out += [0x0D, 0x0A] }
            else { out.append(b) }
        }
        tcp.send(out)
    }

    private func received(_ bytes: [UInt8]) {
        let (text, replies, events) = parser.feed(bytes, wantsOption: { [termType] opt in TelnetParser.supported.contains(opt) && (opt != 24 || !termType.isEmpty) })
        if !replies.isEmpty { tcp.send(replies) }
        for e in events {
            switch e {
            case .naws(let on): nawsEnabled = on; if on { sendNAWS() }
            case .ttypeRequested:
                tcp.send([0xFF, 0xFA, 24, 0] + Array(termType.utf8) + [0xFF, 0xF0])
            }
        }
        if !text.isEmpty { onData?(text) }
    }

    private func sendNAWS() {
        func be(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        var payload: [UInt8] = []
        for b in be(cols) + be(rows) { payload.append(b); if b == 0xFF { payload.append(0xFF) } }
        tcp.send([0xFF, 0xFA, 31] + payload + [0xFF, 0xF0])
    }
}

/// Analizador del flujo Telnet (puro, testeable).
struct TelnetParser {
    enum Event: Equatable { case naws(Bool), ttypeRequested }
    static let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251, SB: UInt8 = 250, SE: UInt8 = 240
    /// Opciones aceptadas: ECHO(1) SGA(3) TTYPE(24) NAWS(31)
    static let supported: Set<UInt8> = [1, 3, 24, 31]

    private enum State { case data, iac, option(UInt8), sb, sbIAC }
    private var state: State = .data
    private var sbBuffer: [UInt8] = []

    /// Devuelve (texto para el terminal, bytes de respuesta, eventos).
    mutating func feed(_ bytes: [UInt8], wantsOption: (UInt8) -> Bool = { supported.contains($0) }) -> ([UInt8], [UInt8], [Event]) {
        var text: [UInt8] = []
        var reply: [UInt8] = []
        var events: [Event] = []
        for b in bytes {
            switch state {
            case .data:
                if b == Self.IAC { state = .iac } else { text.append(b) }
            case .iac:
                switch b {
                case Self.IAC: text.append(0xFF); state = .data
                case Self.DO, Self.DONT, Self.WILL, Self.WONT: state = .option(b)
                case Self.SB: sbBuffer = []; state = .sb
                default: state = .data
                }
            case .option(let verb):
                let ok = wantsOption(b)
                switch verb {
                case Self.DO:
                    reply += [Self.IAC, ok ? Self.WILL : Self.WONT, b]
                    if ok && b == 31 { events.append(.naws(true)) }
                case Self.DONT:
                    reply += [Self.IAC, Self.WONT, b]
                    if b == 31 { events.append(.naws(false)) }
                case Self.WILL: reply += [Self.IAC, (ok && (b == 1 || b == 3)) ? Self.DO : Self.DONT, b]
                case Self.WONT: reply += [Self.IAC, Self.DONT, b]
                default: break
                }
                state = .data
            case .sb:
                if b == Self.IAC { state = .sbIAC } else { sbBuffer.append(b) }
            case .sbIAC:
                if b == Self.SE {
                    if sbBuffer.count >= 2, sbBuffer[0] == 24, sbBuffer[1] == 1 { events.append(.ttypeRequested) }
                    state = .data
                } else if b == Self.IAC { sbBuffer.append(0xFF); state = .sb }
                else { state = .sb }
            }
        }
        return (text, reply, events)
    }
}

// MARK: Puerto serie

@MainActor
final class SerialTransport: ByteTransport {
    var onOpen: (() -> Void)?
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let settings: SerialSettings

    init(settings: SerialSettings) { self.settings = settings }

    func open() {
        fd = Darwin.open(settings.device, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { onClose?(tr("No se puede abrir %@: %@", "\(settings.device)", "\(String(cString: strerror(errno)))")); return }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(settings.baud))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE)
        switch settings.dataBits { case 5: t.c_cflag |= tcflag_t(CS5); case 6: t.c_cflag |= tcflag_t(CS6); case 7: t.c_cflag |= tcflag_t(CS7); default: t.c_cflag |= tcflag_t(CS8) }
        switch settings.parity {
        case "even": t.c_cflag |= tcflag_t(PARENB); t.c_cflag &= ~tcflag_t(PARODD)
        case "odd": t.c_cflag |= tcflag_t(PARENB | PARODD)
        default: t.c_cflag &= ~tcflag_t(PARENB)
        }
        if settings.stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) } else { t.c_cflag &= ~tcflag_t(CSTOPB) }
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        if settings.flow == "rtscts" { t.c_cflag |= tcflag_t(CRTSCTS) }
        if settings.flow == "xonxoff" { t.c_iflag |= tcflag_t(IXON | IXOFF) }
        t.c_cc.16 = 1   // VMIN
        t.c_cc.17 = 0   // VTIME
        tcsetattr(fd, TCSANOW, &t)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(self.fd, &buf, buf.count)
            if n > 0 { self.onData?(Array(buf[0..<n])) }
            else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { self.shutdown(tr("Puerto cerrado")) }
        }
        src.resume()
        source = src
        onOpen?()
    }

    func send(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EAGAIN { usleep(1000); continue }; break }
            off += n
        }
    }

    func resize(cols: Int, rows: Int) {}

    func close() { shutdown(nil, notify: false) }

    private func shutdown(_ msg: String?, notify: Bool = true) {
        source?.cancel(); source = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        if notify { onClose?(msg) }
    }
}

// MARK: Rlogin (RFC 1282)

/// Rlogin sobre TCP: envía "\0usuario_local\0usuario_remoto\0terminal/velocidad\0" y descarta el byte 0 de confirmación.
@MainActor
final class RloginTransport: ByteTransport {
    var onOpen: (() -> Void)?
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?
    private let inner: TCPTransport
    private let user: String
    private var acked = false

    init(host: String, port: Int, user: String) {
        inner = TCPTransport(host: host, port: port)
        self.user = user.isEmpty ? NSUserName() : user
    }

    func open() {
        inner.onOpen = { [weak self] in
            guard let self else { return }
            self.inner.send(Self.handshake(local: NSUserName(), remote: self.user))
            self.onOpen?()
        }
        inner.onData = { [weak self] bytes in
            guard let self else { return }
            var b = bytes[...]
            if !self.acked, b.first == 0 { b = b.dropFirst(); self.acked = true }
            if !b.isEmpty { self.acked = true; self.onData?(Array(b)) }
        }
        inner.onClose = { [weak self] e in self?.onClose?(e) }
        inner.open()
    }

    static func handshake(local: String, remote: String, terminal: String = "xterm-256color/38400") -> [UInt8] {
        [0] + Array(local.utf8) + [0] + Array(remote.utf8) + [0] + Array(terminal.utf8) + [0]
    }

    func send(_ bytes: [UInt8]) { inner.send(bytes) }
    func resize(cols: Int, rows: Int) {
        // ventana: 0xFF 0xFF 's' 's' filas columnas píxeles-x píxeles-y (big-endian)
        func be(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 255), UInt8(v & 255)] }
        inner.send([255, 255, 0x73, 0x73] + be(rows) + be(cols) + be(0) + be(0))
    }
    func close() { inner.close() }
}
