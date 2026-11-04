import Foundation

// MARK: - Serialización binaria del protocolo SFTP v3

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func string(_ s: String) { let d = Data(s.utf8); u32(UInt32(d.count)); data.append(d) }
    mutating func bytes(_ d: Data) { u32(UInt32(d.count)); data.append(d) }
}

struct ByteReader {
    let data: Data
    var pos = 0
    init(_ d: Data) { data = d }
    var remaining: Int { data.count - pos }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPError.protocolError("paquete truncado") }
        defer { pos += 1 }
        return data[data.startIndex + pos]
    }
    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPError.protocolError("paquete truncado") }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[data.startIndex + pos + i]) }
        pos += 4
        return v
    }
    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw SFTPError.protocolError("paquete truncado") }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[data.startIndex + pos + i]) }
        pos += 8
        return v
    }
    mutating func bytes() throws -> Data {
        let n = Int(try u32())
        guard n >= 0, remaining >= n else { throw SFTPError.protocolError("cadena truncada") }
        let d = data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + n))
        pos += n
        return d
    }
    mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
}

enum SFTPError: Error, LocalizedError {
    case status(UInt32, String)
    case closed
    case protocolError(String)
    case launch(String)

    var errorDescription: String? {
        switch self {
        case .status(let c, let m):
            let base = ["OK", "Fin de fichero", "No existe", "Permiso denegado", "Fallo", "Mensaje mal formado", "Sin conexión", "Conexión perdida", "Operación no soportada"]
            let name = Int(c) < base.count ? base[Int(c)] : "Error \(c)"
            return m.isEmpty || m == name ? name : "\(name): \(m)"
        case .closed: return "La conexión SFTP se cerró"
        case .protocolError(let m): return "Error de protocolo SFTP: \(m)"
        case .launch(let m): return m
        }
    }
}

struct RemoteFile: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var size: Int64
    var permissions: UInt32
    var mtime: Date
    var uid: UInt32
    var gid: UInt32

    var typeBits: UInt32 { permissions & 0o170000 }
    var isDirectory: Bool { typeBits == 0o040000 }
    var isSymlink: Bool { typeBits == 0o120000 }
    var isHidden: Bool { name.hasPrefix(".") }

    /// "drwxr-xr-x"
    var permissionString: String {
        let t: String
        switch typeBits {
        case 0o040000: t = "d"
        case 0o120000: t = "l"
        case 0o020000: t = "c"
        case 0o060000: t = "b"
        case 0o010000: t = "p"
        case 0o140000: t = "s"
        default: t = "-"
        }
        let p = permissions
        func tri(_ r: UInt32, _ w: UInt32, _ x: UInt32, special: UInt32, sch: Character) -> String {
            let xs: String = (p & x != 0) ? (p & special != 0 ? String(sch) : "x") : (p & special != 0 ? String(sch).uppercased() : "-")
            return ((p & r != 0) ? "r" : "-") + ((p & w != 0) ? "w" : "-") + xs
        }
        return t + tri(0o400, 0o200, 0o100, special: 0o4000, sch: "s") + tri(0o040, 0o020, 0o010, special: 0o2000, sch: "s") + tri(0o004, 0o002, 0o001, special: 0o1000, sch: "t")
    }
}

// MARK: - Cliente

/// Cliente SFTP v3 nativo: lanza `ssh -s … sftp` (reutiliza la conexión maestra de la sesión) y habla el protocolo binario.
final class SFTPClient: @unchecked Sendable {
    private struct Packet { var type: UInt8; var id: UInt32; var body: Data }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<Packet, Error>] = [:]
    private var closed = false
    private var versionContinuation: CheckedContinuation<Void, Error>?
    private let writeLock = NSLock()
    static let chunk = 32 * 1024
    static let window = 16

    var errorOutput: String {
        let d = (try? stderrPipe.fileHandleForReading.availableData) ?? Data()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start(executable: String, arguments: [String], environment: [String]) async throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env: [String: String] = [:]
        for kv in environment { if let i = kv.firstIndex(of: "=") { env[String(kv[kv.startIndex..<i])] = String(kv[kv.index(after: i)...]) } }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] _ in self?.fail(SFTPError.closed) }
        do { try process.run() } catch { throw SFTPError.launch("No se pudo lanzar ssh: \(error.localizedDescription)") }
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "sftp-reader"
        t.start()
        // INIT → VERSION
        var w = ByteWriter()
        w.u32(3)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); versionContinuation = c; lock.unlock()
            sendRaw(type: 1, payload: w.data)
        }
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        fail(SFTPError.closed)
    }

    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return !closed && process.isRunning }

    // MARK: E/S de bajo nivel

    private func sendRaw(type: UInt8, payload: Data) {
        var pkt = ByteWriter()
        pkt.u32(UInt32(payload.count + 1))
        pkt.u8(type)
        pkt.data.append(payload)
        writeLock.lock()
        try? stdinPipe.fileHandleForWriting.write(contentsOf: pkt.data)
        writeLock.unlock()
    }

    private func readExactly(_ n: Int) -> Data? {
        var buf = Data()
        let fh = stdoutPipe.fileHandleForReading
        while buf.count < n {
            guard let d = try? fh.read(upToCount: n - buf.count), !d.isEmpty else { return nil }
            buf.append(d)
        }
        return buf
    }

    private func readLoop() {
        while true {
            guard let head = readExactly(4) else { break }
            var r = ByteReader(head)
            guard let len = try? r.u32(), len >= 1, len < 1 << 24, let body = readExactly(Int(len)) else { break }
            var br = ByteReader(body)
            guard let type = try? br.u8() else { break }
            if type == 2 {      // VERSION
                lock.lock(); let c = versionContinuation; versionContinuation = nil; lock.unlock()
                c?.resume()
                continue
            }
            guard let id = try? br.u32() else { continue }
            let rest = body.subdata(in: (body.startIndex + 5)..<body.endIndex)
            lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
            c?.resume(returning: Packet(type: type, id: id, body: rest))
        }
        fail(SFTPError.closed)
    }

    private func fail(_ e: Error) {
        lock.lock()
        closed = true
        let p = pending
        pending = [:]
        let v = versionContinuation
        versionContinuation = nil
        lock.unlock()
        v?.resume(throwing: SFTPError.launch(errorOutput.isEmpty ? "No se pudo abrir SFTP (¿conexión SSH no disponible?)" : errorOutput))
        for (_, c) in p { c.resume(throwing: e) }
    }

    private func request(_ type: UInt8, _ build: (inout ByteWriter) -> Void) async throws -> Packet {
        lock.lock()
        if closed { lock.unlock(); throw SFTPError.closed }
        let id = nextID
        nextID &+= 1
        lock.unlock()
        var w = ByteWriter()
        w.u32(id)
        build(&w)
        let pkt: Packet = try await withCheckedThrowingContinuation { c in
            lock.lock()
            if closed { lock.unlock(); c.resume(throwing: SFTPError.closed); return }
            pending[id] = c
            lock.unlock()
            sendRaw(type: type, payload: w.data)
        }
        if pkt.type == 101 {
            var r = ByteReader(pkt.body)
            let code = try r.u32()
            let msg = (try? r.string()) ?? ""
            if code != 0 { throw SFTPError.status(code, msg) }
        }
        return pkt
    }

    private func expectStatusOK(_ p: Packet) throws {
        guard p.type == 101 else { throw SFTPError.protocolError("respuesta inesperada") }
    }

    // MARK: atributos

    private static func parseAttrs(_ r: inout ByteReader) throws -> (size: Int64, uid: UInt32, gid: UInt32, perms: UInt32, mtime: Date) {
        let flags = try r.u32()
        var size: Int64 = 0, uid: UInt32 = 0, gid: UInt32 = 0, perms: UInt32 = 0
        var mtime = Date(timeIntervalSince1970: 0)
        if flags & 0x1 != 0 { size = Int64(bitPattern: try r.u64()) }
        if flags & 0x2 != 0 { uid = try r.u32(); gid = try r.u32() }
        if flags & 0x4 != 0 { perms = try r.u32() }
        if flags & 0x8 != 0 { _ = try r.u32(); mtime = Date(timeIntervalSince1970: TimeInterval(try r.u32())) }
        if flags & 0x80000000 != 0 {
            let n = try r.u32()
            for _ in 0..<n { _ = try r.bytes(); _ = try r.bytes() }
        }
        return (size, uid, gid, perms, mtime)
    }

    // MARK: operaciones

    func realpath(_ path: String) async throws -> String {
        let p = try await request(16) { $0.string(path) }
        guard p.type == 104 else { throw SFTPError.protocolError("REALPATH") }
        var r = ByteReader(p.body)
        _ = try r.u32()
        return try r.string()
    }

    func stat(_ path: String, followLinks: Bool = true) async throws -> RemoteFile {
        let p = try await request(followLinks ? 17 : 7) { $0.string(path) }
        guard p.type == 105 else { throw SFTPError.protocolError("STAT") }
        var r = ByteReader(p.body)
        let a = try Self.parseAttrs(&r)
        let name = (path as NSString).lastPathComponent
        return RemoteFile(name: name, path: path, size: a.size, permissions: a.perms, mtime: a.mtime, uid: a.uid, gid: a.gid)
    }

    func list(_ dir: String) async throws -> [RemoteFile] {
        let h = try await request(11) { $0.string(dir) }
        guard h.type == 102 else { throw SFTPError.protocolError("OPENDIR") }
        var hr = ByteReader(h.body)
        let handle = try hr.bytes()
        defer { Task { _ = try? await self.request(4) { $0.bytes(handle) } } }
        var out: [RemoteFile] = []
        while true {
            let p: Packet
            do { p = try await request(12) { $0.bytes(handle) } }
            catch SFTPError.status(let c, _) where c == 1 { break }
            guard p.type == 104 else { throw SFTPError.protocolError("READDIR") }
            var r = ByteReader(p.body)
            let n = try r.u32()
            for _ in 0..<n {
                let name = try r.string()
                _ = try r.string()
                let a = try Self.parseAttrs(&r)
                if !SessionSafety.isSafeRemoteName(name) { continue }      // un servidor malicioso no puede sacar descargas de su carpeta
                let full = dir == "/" ? "/" + name : (dir.hasSuffix("/") ? dir + name : dir + "/" + name)
                out.append(RemoteFile(name: name, path: full, size: a.size, permissions: a.perms, mtime: a.mtime, uid: a.uid, gid: a.gid))
            }
        }
        return out
    }

    func mkdir(_ path: String, mode: UInt32 = 0o755) async throws {
        _ = try await request(14) { w in w.string(path); w.u32(0x4); w.u32(mode) }
    }

    func rmdir(_ path: String) async throws { _ = try await request(15) { $0.string(path) } }
    func remove(_ path: String) async throws { _ = try await request(13) { $0.string(path) } }
    func rename(_ from: String, to: String) async throws { _ = try await request(18) { w in w.string(from); w.string(to) } }

    func chmod(_ path: String, mode: UInt32) async throws {
        _ = try await request(9) { w in w.string(path); w.u32(0x4); w.u32(mode) }
    }

    func readlink(_ path: String) async throws -> String {
        let p = try await request(19) { $0.string(path) }
        var r = ByteReader(p.body)
        _ = try r.u32()
        return try r.string()
    }

    /// Borra recursivamente un fichero o directorio.
    func removeRecursive(_ file: RemoteFile) async throws {
        if file.isDirectory && !file.isSymlink {
            for child in try await list(file.path) { try await removeRecursive(child) }
            try await rmdir(file.path)
        } else {
            try await remove(file.path)
        }
    }

    // MARK: transferencias

    private func openHandle(_ path: String, flags: UInt32) async throws -> Data {
        let p = try await request(3) { w in w.string(path); w.u32(flags); w.u32(0x4); w.u32(0o644) }
        guard p.type == 102 else { throw SFTPError.protocolError("OPEN") }
        var r = ByteReader(p.body)
        return try r.bytes()
    }

    private func closeHandle(_ h: Data) async { _ = try? await request(4) { $0.bytes(h) } }

    /// Descarga un fichero con lecturas en paralelo. `progress(bytes, total)`.
    func download(remote: String, to local: URL, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let size = try await stat(remote).size
        let h = try await openHandle(remote, flags: 0x1)
        defer { Task { await self.closeHandle(h) } }
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let fd = open(local.path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { throw SFTPError.launch("No se puede escribir \(local.path)") }
        defer { Darwin.close(fd) }
        var done: Int64 = 0
        let chunk = Int64(Self.chunk)
        var offset: Int64 = 0
        let total = max(size, 0)
        if total == 0 { progress(0, 0); return }
        try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
            func issue() {
                guard offset < total else { return }
                let o = offset
                let len = UInt32(min(chunk, total - o))
                offset += Int64(len)
                group.addTask {
                    let p = try await self.request(5) { w in w.bytes(h); w.u64(UInt64(o)); w.u32(len) }
                    guard p.type == 103 else { throw SFTPError.protocolError("READ") }
                    var r = ByteReader(p.body)
                    return (o, try r.bytes())
                }
            }
            for _ in 0..<Self.window { issue() }
            while let (o, d) = try await group.next() {
                try Task.checkCancellation()
                _ = d.withUnsafeBytes { pwrite(fd, $0.baseAddress, d.count, off_t(o)) }
                done += Int64(d.count)
                progress(done, total)
                issue()
            }
        }
    }

    /// Sube un fichero con escrituras en paralelo.
    func upload(local: URL, to remote: String, mode: UInt32 = 0o644, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: local.path)
        let total = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let perm = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? mode
        let h = try await openHandle(remote, flags: 0x2 | 0x8 | 0x10)
        defer { Task { await self.closeHandle(h) } }
        guard let fh = try? FileHandle(forReadingFrom: local) else { throw SFTPError.launch("No se puede leer \(local.path)") }
        defer { try? fh.close() }
        var offset: Int64 = 0
        var done: Int64 = 0
        if total == 0 { progress(0, 0) }
        try await withThrowingTaskGroup(of: Int64.self) { group in
            func issue() throws {
                guard offset < total else { return }
                try fh.seek(toOffset: UInt64(offset))
                let data = try fh.read(upToCount: Self.chunk) ?? Data()
                guard !data.isEmpty else { return }
                let o = offset
                offset += Int64(data.count)
                group.addTask {
                    _ = try await self.request(6) { w in w.bytes(h); w.u64(UInt64(o)); w.bytes(data) }
                    return Int64(data.count)
                }
            }
            for _ in 0..<Self.window { try issue() }
            while let n = try await group.next() {
                try Task.checkCancellation()
                done += n
                progress(done, total)
                try issue()
            }
        }
        try? await chmod(remote, mode: perm & 0o7777)
    }

    func readFile(_ path: String, maxBytes: Int64 = 64 * 1024 * 1024) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let size = try await stat(path).size
        guard size <= maxBytes else { throw SFTPError.launch("El archivo es demasiado grande para abrirlo aquí") }
        try await download(remote: path, to: tmp)
        return (try? Data(contentsOf: tmp)) ?? Data()
    }

    func writeFile(_ data: Data, to path: String) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID().uuidString)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await upload(local: tmp, to: path)
    }
}
