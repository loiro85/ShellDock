import XCTest
@testable import ShellDock

enum TestServer {
    static let host = "127.0.0.1"
    static let port = 2222
    static let key = "/tmp/sd-test/client_ed25519"

    static var available: Bool {
        guard FileManager.default.fileExists(atPath: key) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-z", "-G", "1", host, String(port)]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func session() -> Session {
        var s = Session()
        s.name = "test"
        s.host = host
        s.port = port
        s.username = NSUserName()
        s.auth = .key
        s.keyPath = key
        s.keepAlive = 0
        return s
    }

    static func skipIfUnavailable() throws {
        try XCTSkipUnless(available, "Arranca el servidor de pruebas: scripts/testserver.sh start")
    }
}
