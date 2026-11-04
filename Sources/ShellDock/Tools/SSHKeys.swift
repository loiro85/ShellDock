import Foundation

struct SSHKeyInfo: Identifiable, Hashable {
    var id: String { path }
    var path: String          // clave privada
    var name: String { (path as NSString).lastPathComponent }
    var publicPath: String { path + ".pub" }
    var fingerprint = ""
    var type = ""
    var bits = ""
    var comment = ""
    var hasPublic: Bool { FileManager.default.fileExists(atPath: publicPath) }
}

enum SSHKeys {
    static var sshDir: String { NSHomeDirectory() + "/.ssh" }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Claves privadas en un directorio (ficheros con cabecera PEM/OpenSSH).
    static func list(in dir: String = sshDir) -> [SSHKeyInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var out: [SSHKeyInfo] = []
        for f in files.sorted() where !f.hasSuffix(".pub") && !["known_hosts", "known_hosts.old", "config", "authorized_keys", "environment"].contains(f) {
            let path = dir + "/" + f
            guard let h = FileHandle(forReadingAtPath: path), let head = try? h.read(upToCount: 40), String(decoding: head, as: UTF8.self).hasPrefix("-----BEGIN") else { continue }
            var k = SSHKeyInfo(path: path)
            let (st, o) = run("/usr/bin/ssh-keygen", ["-l", "-f", FileManager.default.fileExists(atPath: path + ".pub") ? path + ".pub" : path])
            if st == 0 {
                // "256 SHA256:xxxx comentario (ED25519)"
                let parts = o.split(separator: " ", maxSplits: 2).map(String.init)
                if parts.count >= 3 {
                    k.bits = parts[0]
                    k.fingerprint = parts[1]
                    if let r = parts[2].range(of: " (", options: .backwards) { k.comment = String(parts[2][parts[2].startIndex..<r.lowerBound]); k.type = String(parts[2][r.upperBound...]).replacingOccurrences(of: ")", with: "") }
                    else { k.comment = parts[2] }
                }
            }
            out.append(k)
        }
        return out
    }

    static func generate(name: String, type: String, bits: Int?, comment: String, passphrase: String, in dir: String = sshDir) -> (Bool, String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = dir + "/" + name
        guard !FileManager.default.fileExists(atPath: path) else { return (false, tr("Ya existe %@", "\(name)")) }
        var args = ["-q", "-t", type, "-f", path, "-N", passphrase, "-C", comment]
        if let b = bits, type == "rsa" || type == "ecdsa" { args += ["-b", String(b)] }
        let (st, out) = run("/usr/bin/ssh-keygen", args)
        return (st == 0, out)
    }

    static func publicKey(_ k: SSHKeyInfo) -> String? { try? String(contentsOfFile: k.publicPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
}
