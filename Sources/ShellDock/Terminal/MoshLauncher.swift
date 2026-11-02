import Foundation

/// Mosh: usa el cliente `mosh` instalado (Homebrew o MacPorts); la autenticación la hace ssh.
enum MoshLauncher {
    static func executable() -> String? {
        ["/opt/homebrew/bin/mosh", "/usr/local/bin/mosh", "/opt/local/bin/mosh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func arguments(for s: Session) -> [String] {
        var ssh = "ssh"
        if s.port != 22 && s.port > 0 { ssh += " -p \(s.port)" }
        if !s.keyPath.isEmpty { ssh += " -i \(ShellSplit.quote((s.keyPath as NSString).expandingTildeInPath))" }
        var a: [String] = []
        if ssh != "ssh" { a.append("--ssh=\(ssh)") }
        a.append(s.username.isEmpty ? s.host : "\(s.username)@\(s.host)")
        let cmd = s.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cmd.isEmpty { a += ["--", "sh", "-c", cmd] }
        return a
    }
}
