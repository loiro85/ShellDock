import Foundation

enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case ssh, sftp, telnet, tcp, serial, vnc, rdp, ftp, local, miniLinux, mosh, rlogin, browser
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh: return "SSH"
        case .sftp: return "SFTP"
        case .telnet: return "Telnet"
        case .tcp: return tr("TCP crudo")
        case .serial: return tr("Serie")
        case .vnc: return "VNC"
        case .rdp: return "RDP"
        case .ftp: return "FTP"
        case .local: return tr("Terminal local")
        case .miniLinux: return "Mini Linux"
        case .mosh: return "Mosh"
        case .rlogin: return "Rlogin"
        case .browser: return tr("Navegador")
        }
    }

    var symbol: String {
        switch self {
        case .ssh: return "terminal"
        case .sftp: return "folder.badge.gearshape"
        case .telnet: return "network"
        case .tcp: return "point.3.connected.trianglepath.dotted"
        case .serial: return "cable.connector"
        case .vnc: return "display"
        case .rdp: return "rectangle.on.rectangle"
        case .ftp: return "arrow.up.arrow.down.square"
        case .local: return "apple.terminal"
        case .miniLinux: return "shippingbox"
        case .mosh: return "bolt.horizontal.circle"
        case .rlogin: return "arrow.right.to.line"
        case .browser: return "globe"
        }
    }

    var defaultPort: Int {
        switch self {
        case .ssh, .sftp, .mosh: return 22
        case .rlogin: return 513
        case .telnet: return 23
        case .tcp: return 0
        case .vnc: return 5900
        case .rdp: return 3389
        case .ftp: return 21
        default: return 0
        }
    }

    var needsHost: Bool { [.ssh, .sftp, .telnet, .tcp, .vnc, .rdp, .ftp, .mosh, .rlogin, .browser].contains(self) }
}

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case auto, password, key, agent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return tr("Automático")
        case .password: return tr("Contraseña")
        case .key: return tr("Clave privada")
        case .agent: return tr("Agente SSH")
        }
    }
}

enum TunnelKind: String, Codable, CaseIterable, Identifiable {
    case local, remote, dynamic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return tr("Local (-L)")
        case .remote: return tr("Remoto (-R)")
        case .dynamic: return tr("Dinámico SOCKS (-D)")
        }
    }
}

struct Tunnel: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var kind: TunnelKind = .local
    var bindHost = "127.0.0.1"
    var bindPort = 8080
    var targetHost = "localhost"
    var targetPort = 80

    /// Argumento para `ssh` (p. ej. `-L 127.0.0.1:8080:localhost:80`).
    var sshArguments: [String] {
        switch kind {
        case .local: return ["-L", "\(bindHost):\(bindPort):\(targetHost):\(targetPort)"]
        case .remote: return ["-R", "\(bindHost):\(bindPort):\(targetHost):\(targetPort)"]
        case .dynamic: return ["-D", "\(bindHost):\(bindPort)"]
        }
    }

    var summary: String {
        switch kind {
        case .local: return "\(bindHost):\(bindPort) → \(targetHost):\(targetPort)"
        case .remote: return "remoto \(bindHost):\(bindPort) → \(targetHost):\(targetPort)"
        case .dynamic: return "SOCKS \(bindHost):\(bindPort)"
        }
    }
}

struct SerialSettings: Codable, Hashable {
    var device = ""
    var baud = 115200
    var dataBits = 8
    var parity = "none"       // none, even, odd
    var stopBits = 1
    var flow = "none"         // none, rtscts, xonxoff
}

struct Session: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = tr("Nueva sesión")
    var kind: SessionKind = .ssh
    var host = ""
    var port = 22
    var username = ""
    var folderID: UUID?
    var colorHex: String?
    var notes = ""

    // autenticación
    var auth: AuthMethod = .auto
    var keyPath = ""
    var hasStoredPassword = false     // la contraseña vive en el Llavero (cuenta = id)
    var hasStoredPassphrase = false

    // SSH
    var jumpHost = ""
    var x11Forwarding = false
    var x11Trusted = false
    var agentForwarding = false
    var compression = false
    var keepAlive = 30
    var startupCommand = ""
    var extraArguments = ""
    var autoReconnect = false
    var openFileBrowser = true
    var tunnels: [Tunnel] = []

    // serie
    var serial = SerialSettings()

    // FTP
    var ftpTLS = false

    // Mini Linux (VM)
    var vmMemoryMB = 0
    var vmCPUs = 0
    var sharedFolder = ""

    // VNC / RDP
    var rdpDomain = ""
    var rdpResolution = ""

    // apariencia
    var themeName = ""
    var fontSize = 0

    var displayAddress: String {
        switch kind {
        case .serial: return serial.device
        case .local: return "este Mac"
        case .miniLinux: return tr("máquina virtual")
        default:
            let u = username.isEmpty ? "" : "\(username)@"
            let p = port == kind.defaultPort || port == 0 ? "" : ":\(port)"
            return "\(u)\(host)\(p)"
        }
    }
}

struct Folder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = tr("Carpeta")
    var parentID: UUID?
    var expanded = true
    var colorHex: String?
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = tr("Nuevo snippet")
    var text = ""
    var sendReturn = true
}

struct SavedTunnel: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = tr("Túnel")
    var sessionID: UUID?
    var tunnel = Tunnel()
}
