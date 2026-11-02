import Foundation

/// Integración con XQuartz (servidor X11 de macOS).
enum X11 {
    static var installed: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Utilities/XQuartz.app") || FileManager.default.fileExists(atPath: "/opt/X11/bin/Xquartz")
    }

    /// Valor de DISPLAY gestionado por launchd si XQuartz está instalado.
    static func displayValue() -> String? {
        if let d = ProcessInfo.processInfo.environment["DISPLAY"], !d.isEmpty { return d }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["getenv", "DISPLAY"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !s.isEmpty { return s }
        return installed ? ":0" : nil
    }

    static func startServer() {
        guard installed else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "XQuartz"]
        try? p.run()
    }
}
