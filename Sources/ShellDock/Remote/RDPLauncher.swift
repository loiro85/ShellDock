import AppKit

/// RDP: genera un archivo .rdp y lo abre con el cliente instalado (Windows App / Microsoft Remote Desktop).
/// Incrustar RDP dentro de la ventana exigiría FreeRDP; se documenta como limitación.
enum RDPLauncher {
    static func contents(for s: Session) -> String {
        // un salto de línea en un campo añadiría opciones al .rdp (p. ej. un "alternate shell")
        let host = SessionSafety.stripControl(s.host), user = SessionSafety.stripControl(s.username), domain = SessionSafety.stripControl(s.rdpDomain)
        var lines = ["full address:s:\(host):\(s.port > 0 ? s.port : 3389)"]
        if !user.isEmpty { lines.append("username:s:\(domain.isEmpty ? "" : domain + "\\")\(user)") }
        let parts = SessionSafety.stripControl(s.rdpResolution).lowercased().split(separator: "x").compactMap { Int($0) }
        if parts.count == 2 {
            lines += ["desktopwidth:i:\(parts[0])", "desktopheight:i:\(parts[1])", "screen mode id:i:1"]
        } else {
            lines.append("screen mode id:i:2")
        }
        lines += ["session bpp:i:32", "authentication level:i:2", "prompt for credentials:i:1", "redirectclipboard:i:1"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Devuelve el aviso que se muestra al usuario.
    @MainActor
    static func open(_ s: Session) -> String {
        let dir = Paths.appSupport.appendingPathComponent("rdp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = SessionSafety.stripControl(s.name).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "..", with: "_")
        let url = dir.appendingPathComponent("\(safe).rdp")
        do { try contents(for: s).write(to: url, atomically: true, encoding: .utf8) }
        catch { return "RDP: no se pudo crear el archivo (\(error.localizedDescription))" }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return "RDP: instala «Windows App» (Mac App Store) para abrir sesiones de escritorio remoto"
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return "RDP: abierto con \(app.deletingPathExtension().lastPathComponent)"
    }
}
