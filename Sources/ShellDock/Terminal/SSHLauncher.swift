import Foundation

/// Descripción de un proceso a lanzar en un pty.
struct LaunchSpec {
    var executable: String
    var args: [String]
    var env: [String]
    var cwd: String?
    var display: String           // línea de comandos legible
}

/// Construye la orden `ssh`/`sftp` de una sesión con todas sus opciones.
enum SSHLauncher {
    static let sshPath = "/usr/bin/ssh"

    /// Argumentos que identifican el destino (los mismos para ssh y sftp, para compartir el ControlMaster).
    static func targetArguments(_ s: Session) -> [String] {
        var a: [String] = []
        if s.port != 22 && s.port > 0 { a += ["-p", String(s.port)] }
        if !s.username.isEmpty { a += ["-l", s.username] }
        return a
    }

    static func controlPath() -> String { "\(Paths.controlDir)/%C" }

    static func commonOptions(_ s: Session, hostKeyPolicy: String, master: Bool) -> [String] {
        var a: [String] = []
        if master {
            a += ["-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath())"]
        } else {
            a += ["-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath())"]
        }
        if s.keepAlive > 0 {
            a += ["-o", "ServerAliveInterval=\(s.keepAlive)", "-o", "ServerAliveCountMax=4"]
        }
        switch hostKeyPolicy {
        case "no": a += ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"]
        case "ask": break
        default: a += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if !s.keyPath.isEmpty && s.auth != .password && s.auth != .agent {
            a += ["-i", (s.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        switch s.auth {
        case .password: a += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        case .key: a += ["-o", "PreferredAuthentications=publickey"]
        case .agent: a += ["-o", "PreferredAuthentications=publickey", "-o", "IdentitiesOnly=no"]
        case .auto: break
        }
        if !s.jumpHost.trimmingCharacters(in: .whitespaces).isEmpty { a += ["-J", s.jumpHost.trimmingCharacters(in: .whitespaces)] }
        return a
    }

    static func environment(for s: Session?, extra: [String] = []) -> [String] {
        var env = ProcessEnvironment.base()
        if let s {
            if s.hasStoredPassword || s.hasStoredPassphrase {
                AskPass.install()
                env.append("SHELLDOCK_ACCOUNT=\(s.id.uuidString)")
                env.append("SHELLDOCK_SOCK=\(AskPassServer.shared.socketPath)")
                env.append("SHELLDOCK_TOKEN=\(AskPassServer.shared.token)")
                env.append("SSH_ASKPASS=\(Paths.askpassPath)")
                env.append("SSH_ASKPASS_REQUIRE=force")
            }
            if s.x11Forwarding, let d = X11.displayValue() { env.removeAll { $0.hasPrefix("DISPLAY=") }; env.append("DISPLAY=\(d)") }
        }
        return env + extra
    }

    /// Orden completa para una sesión SSH interactiva.
    static func spec(for s: Session, settings: AppSettingsData, logFile: URL? = nil) -> LaunchSpec {
        var args: [String] = []
        args += commonOptions(s, hostKeyPolicy: settings.hostKeyPolicy, master: true)
        args += targetArguments(s)
        if s.x11Forwarding { args.append(s.x11Trusted ? "-Y" : "-X") }
        if s.agentForwarding { args.append("-A") }
        if s.compression { args.append("-C") }
        for t in s.tunnels { args += t.sshArguments }
        args += ShellSplit.split(s.extraArguments)
        args.append(s.host)
        let cmd = s.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cmd.isEmpty {
            args.insert("-t", at: 0)
            args.append("\(cmd); exec \"$SHELL\" -l")
        }
        var exe = sshPath
        var finalArgs = args
        if let log = logFile {
            // `script` registra todo lo que ocurre en el pty
            finalArgs = ["-q", log.path, sshPath] + args
            exe = "/usr/bin/script"
        }
        let display = ([ "ssh" ] + args.map(ShellSplit.quote)).joined(separator: " ")
        return LaunchSpec(executable: exe, args: finalArgs, env: environment(for: s), cwd: nil, display: display)
    }

    /// `ssh -s host sftp`: subsistema SFTP sobre la conexión maestra (o una nueva si no existe).
    static func sftpSubsystemArguments(_ s: Session, hostKeyPolicy: String) -> [String] {
        var a = commonOptions(s, hostKeyPolicy: hostKeyPolicy, master: false)
        a += targetArguments(s)
        a += ["-o", "ConnectTimeout=15", "-s", s.host, "sftp"]
        return a
    }

    /// ¿Hay ya una conexión maestra abierta para esta sesión? (la usa el panel de archivos para esperar al login)
    static func masterIsAlive(_ s: Session, hostKeyPolicy: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sshPath)
        p.arguments = ["-o", "ControlPath=\(controlPath())"] + targetArguments(s) + ["-O", "check", s.host]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// `sftp` en modo batch que reutiliza la conexión maestra de la sesión.
    static func sftpArguments(_ s: Session, hostKeyPolicy: String) -> [String] {
        var a = commonOptions(s, hostKeyPolicy: hostKeyPolicy, master: false)
        a += ["-o", "BatchMode=no"]
        if s.port != 22 && s.port > 0 { a += ["-P", String(s.port)] }
        a += ["-b", "-"]
        a.append(s.username.isEmpty ? s.host : "\(s.username)@\(s.host)")
        return a
    }
}

/// Entorno base de los procesos lanzados en terminales.
enum ProcessEnvironment {
    static func base(toolbox: Bool = true) -> [String] {
        let pe = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": pe["LANG"] ?? "en_US.UTF-8",
            "HOME": pe["HOME"] ?? NSHomeDirectory(), "USER": pe["USER"] ?? NSUserName(), "LOGNAME": pe["LOGNAME"] ?? NSUserName(),
            "SHELL": pe["SHELL"] ?? "/bin/zsh", "TMPDIR": pe["TMPDIR"] ?? "/tmp",
            "TERM_PROGRAM": "ShellDock",
        ]
        for k in ["SSH_AUTH_SOCK", "DISPLAY", "LC_ALL", "LC_CTYPE", "http_proxy", "https_proxy", "no_proxy"] { if let v = pe[k] { env[k] = v } }
        var path = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if toolbox && FileManager.default.fileExists(atPath: Paths.toolboxBin.path) { path.insert(Paths.toolboxBin.path, at: 0) }
        env["PATH"] = path.joined(separator: ":")
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }
}

/// Ayudante `SSH_ASKPASS`: pide la contraseña/frase de paso a la app por un socket privado o muestra un diálogo nativo.
enum AskPass {
    static let script = #"""
    #!/bin/sh
    # ShellDock askpass. Variables: SHELLDOCK_ACCOUNT (id de sesión), SHELLDOCK_SOCK, SHELLDOCK_TOKEN.
    prompt="$1"
    kind=password
    case "$prompt" in
      *assphrase*) kind=passphrase ;;
      *"(yes/no"*)
        [ -n "$SHELLDOCK_NODIALOG" ] && exit 1
        /usr/bin/osascript -e 'on run argv' -e 'button returned of (display dialog (item 1 of argv) buttons {"no", "yes"} default button "yes" with title "ShellDock")' -e 'end run' "$prompt" 2>/dev/null; exit $? ;;
    esac
    if [ -n "$SHELLDOCK_SOCK" ] && [ -n "$SHELLDOCK_ACCOUNT" ]; then
      pw=$(printf '%s\t%s\t%s\n' "$SHELLDOCK_TOKEN" "$SHELLDOCK_ACCOUNT" "$kind" | /usr/bin/nc -U "$SHELLDOCK_SOCK" 2>/dev/null)
      if [ -n "$pw" ]; then printf '%s\n' "$pw"; exit 0; fi
    fi
    [ -n "$SHELLDOCK_NODIALOG" ] && exit 1
    /usr/bin/osascript -e 'on run argv' -e 'text returned of (display dialog (item 1 of argv) default answer "" with hidden answer with title "ShellDock")' -e 'end run' "$prompt" 2>/dev/null
    """#

    static func install() {
        AskPassServer.shared.start()
        let path = Paths.askpassPath
        let body = script.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }.joined(separator: "\n")
        if (try? String(contentsOfFile: path, encoding: .utf8)) == body { return }
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
