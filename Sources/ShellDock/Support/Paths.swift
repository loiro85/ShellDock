import Foundation

/// Rutas de la aplicación (configuración, sockets de multiplexado SSH, herramientas, imágenes de la VM).
enum Paths {
    static let fm = FileManager.default

    static var appSupport: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ShellDock", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sub(_ name: String) -> URL {
        let d = appSupport.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var binDir: URL { sub("bin") }
    static var logsDir: URL { sub("logs") }
    static var vmDir: URL { sub("minilinux") }
    static var sessionsFile: URL { appSupport.appendingPathComponent("sessions.json") }
    static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }

    /// Directorio corto para los sockets de ControlMaster (el límite de ruta de un socket Unix es ~104 bytes).
    static var controlDir: String {
        let d = "/tmp/shelldock-\(getuid())"
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }

    static var askpassPath: String { binDir.appendingPathComponent("shelldock-askpass").path }

    /// Caja de herramientas Unix propia (si existe) que se antepone al PATH del terminal local.
    static var toolboxBin: URL { appSupport.appendingPathComponent("toolbox/bin", isDirectory: true) }
}
