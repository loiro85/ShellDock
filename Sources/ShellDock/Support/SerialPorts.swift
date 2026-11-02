import Foundation

enum SerialPorts {
    /// Dispositivos serie del sistema (`/dev/cu.*`).
    static func list() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return all.filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/" + $0 }
    }
}
