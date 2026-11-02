import Foundation
import Darwin

/// Servidor en un socket Unix privado que entrega a `shelldock-askpass` las contraseñas guardadas en el Llavero.
/// La app es la única que toca el Llavero (sin diálogos de permiso); el ayudante solo presenta un token por ejecución.
final class AskPassServer: @unchecked Sendable {
    static let shared = AskPassServer()
    let token = UUID().uuidString
    let socketPath: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "shelldock.askpass")
    private let lock = NSLock()
    private var started = false

    init(path: String? = nil) {
        socketPath = path ?? "\(Paths.controlDir)/askpass.sock"
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { Darwin.close(fd); return }
        chmod(socketPath, 0o600)
        listen(fd, 8)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
        started = true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        source?.cancel(); source = nil
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        unlink(socketPath)
        started = false
    }

    private func acceptOne() {
        let c = accept(listenFD, nil, nil)
        guard c >= 0 else { return }
        queue.async { [token] in
            defer { Darwin.close(c) }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 512)
            while data.count < 4096 {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
                if data.contains(0x0A) { break }
            }
            let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.components(separatedBy: "\t")
            var reply = "\n"
            if parts.count == 3, parts[0] == token, UUID(uuidString: parts[1]) != nil {
                let account = parts[2] == "passphrase" ? parts[1] + ".passphrase" : parts[1]
                if let pw = Keychain.get(account: account), !pw.contains("\n") { reply = pw + "\n" }
            }
            let out = Array(reply.utf8)
            _ = out.withUnsafeBytes { write(c, $0.baseAddress, out.count) }
        }
    }
}
