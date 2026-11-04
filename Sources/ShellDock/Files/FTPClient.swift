import Foundation

/// Cliente FTP/FTPS sobre `/usr/bin/curl` (la contraseña se entrega por stdin con `-K -`, nunca en la línea de comandos).
final class FTPClient: RemoteFS, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let tls: Bool

    init(session: Session, passwordOverride: String? = nil) {
        host = session.host
        port = session.port > 0 ? session.port : 21
        user = session.username.isEmpty ? "anonymous" : session.username
        password = passwordOverride ?? Keychain.get(account: session.id.uuidString) ?? (session.username.isEmpty ? "anonymous@" : "")
        tls = session.ftpTLS
    }

    // MARK: curl

    private func baseURL(_ path: String, dir: Bool = false) -> String {
        var p = path.hasPrefix("/") ? path : "/" + path
        if dir && !p.hasSuffix("/") { p += "/" }
        let enc = p.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? p
        return "ftp://\(host):\(port)\(enc)"
    }

    private func curl(_ args: [String], timeout: Int = 30) async throws -> Data {
        try await Task.detached { [self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            var a = ["-sS", "--max-time", String(timeout), "--connect-timeout", "10", "--ftp-method", "singlecwd", "-K", "-"]
            if tls { a += ["--ssl-reqd", "--insecure"] }
            p.arguments = a + args
            let inPipe = Pipe(), out = Pipe(), err = Pipe()
            p.standardInput = inPipe
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            inPipe.fileHandleForWriting.write(Data("user = \"\(esc(user)):\(esc(password))\"\n".utf8))
            try? inPipe.fileHandleForWriting.close()
            // leer ambos flujos mientras corre (evita bloqueos por tuberías llenas)
            var outData = Data(), errData = Data()
            let g = DispatchGroup()
            g.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            g.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            p.waitUntilExit()
            g.wait()
            guard p.terminationStatus == 0 else {
                let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let code: UInt32
                switch p.terminationStatus {
                case 9, 19, 78, 25: code = 2          // no existe / acceso
                case 67, 10: code = 3                 // login rechazado
                case 7, 6, 28: code = 7               // sin conexión
                default: code = 4
                }
                throw SFTPError.status(code, msg.isEmpty ? tr("curl terminó con código %@", "\(p.terminationStatus)") : msg)
            }
            return outData
        }.value
    }

    func connect() async throws { _ = try await curl([baseURL("/", dir: true), "--list-only"]) }

    // MARK: RemoteFS

    func realpath(_ path: String) async throws -> String {
        if path == "." || path.isEmpty { return "/" }
        var parts: [String] = []
        for c in path.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast() } else { parts.append(String(c)) }
        }
        return "/" + parts.joined(separator: "/")
    }

    func list(_ dir: String) async throws -> [RemoteFile] {
        let d = try await curl([baseURL(dir, dir: true)])
        return Self.parseListing(String(decoding: d, as: UTF8.self), in: dir)
    }

    func stat(_ path: String, followLinks: Bool) async throws -> RemoteFile {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if path == "/" { return RemoteFile(name: "/", path: "/", size: 0, permissions: 0o040755, mtime: Date(), uid: 0, gid: 0) }
        guard let f = try await list(parent.isEmpty ? "/" : parent).first(where: { $0.name == name }) else { throw SFTPError.status(2, tr("No existe")) }
        return f
    }

    private func check(_ paths: String...) throws { for p in paths where !SessionSafety.isSafeFTPPath(p) { throw SFTPError.protocolError("Ruta no válida") } }
    func mkdir(_ path: String, mode: UInt32) async throws { try check(path); _ = try await curl([baseURL("/", dir: true), "-Q", "MKD \(path)", "--list-only"]) }
    func rename(_ from: String, to: String) async throws { try check(from, to); _ = try await curl([baseURL("/", dir: true), "-Q", "-RNFR \(from)", "-Q", "-RNTO \(to)", "--list-only"]) }
    func chmod(_ path: String, mode: UInt32) async throws { try check(path); _ = try await curl([baseURL("/", dir: true), "-Q", "SITE CHMOD \(String(mode & 0o7777, radix: 8)) \(path)", "--list-only"]) }

    func removeRecursive(_ file: RemoteFile) async throws {
        if file.isDirectory {
            for c in try await list(file.path) { try await removeRecursive(c) }
            _ = try await curl([baseURL("/", dir: true), "-Q", "RMD \(file.path)", "--list-only"])
        } else {
            _ = try await curl([baseURL("/", dir: true), "-Q", "DELE \(file.path)", "--list-only"])
        }
    }

    func download(remote: String, to local: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let size = (try? await stat(remote, followLinks: true).size) ?? 0
        _ = try await curl(["-o", local.path, baseURL(remote)], timeout: 3600)
        progress(size, size)
    }

    func upload(local: URL, to remote: String, mode: UInt32, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = ((try? FileManager.default.attributesOfItem(atPath: local.path)[.size]) as? NSNumber)?.int64Value ?? 0
        _ = try await curl(["-T", local.path, "--ftp-create-dirs", baseURL(remote)], timeout: 3600)
        progress(total, total)
    }

    func close() {}

    // MARK: listado UNIX

    /// Interpreta la salida de `LIST` estilo UNIX: "drwxr-xr-x 2 user group 4096 Nov  2 10:00 nombre".
    static func parseListing(_ text: String, in dir: String) -> [RemoteFile] {
        var out: [RemoteFile] = []
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: Date())
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 9, let first = f[0].first, "-dlcbps".contains(first), f[0].count >= 10 else { continue }
            guard let size = Int64(f[4]), let mi = months.firstIndex(of: String(f[5])), let day = Int(f[6]) else { continue }
            // nombre = todo lo que sigue a los 8 primeros campos (puede tener espacios)
            var idx = line.startIndex
            for _ in 0..<8 {
                while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
                while idx < line.endIndex, line[idx] != " " { idx = line.index(after: idx) }
            }
            while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
            var name = String(line[idx...])
            if first == "l", let r = name.range(of: " -> ") { name = String(name[name.startIndex..<r.lowerBound]) }
            if !SessionSafety.isSafeRemoteName(name) { continue }
            var comps = DateComponents(year: year, month: mi + 1, day: day)
            let t = String(f[7])
            if t.contains(":") { let hm = t.split(separator: ":").compactMap { Int($0) }; comps.hour = hm.first; comps.minute = hm.count > 1 ? hm[1] : 0 }
            else if let y = Int(t) { comps.year = y }
            var date = cal.date(from: comps) ?? Date(timeIntervalSince1970: 0)
            if date > Date().addingTimeInterval(86400 * 2) && t.contains(":") { comps.year = year - 1; date = cal.date(from: comps) ?? date }
            var perm: UInt32 = 0
            let rwx = Array(f[0].dropFirst())
            let bits: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
            for (i, ch) in rwx.prefix(9).enumerated() where ch != "-" && ch != "S" && ch != "T" { perm |= bits[i] }
            switch first { case "d": perm |= 0o040000; case "l": perm |= 0o120000; default: perm |= 0o100000 }
            let full = dir == "/" ? "/" + name : (dir.hasSuffix("/") ? dir + name : dir + "/" + name)
            out.append(RemoteFile(name: name, path: full, size: size, permissions: perm, mtime: date, uid: 0, gid: 0))
        }
        return out
    }
}
