import XCTest
@testable import ShellDock

final class FTPTests: XCTestCase {
    var server: Process?
    var root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-ftp-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ftpserver.py")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script.path, "23421", root.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        XCTAssertTrue(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).contains("READY"))
        server = p
    }

    override func tearDown() {
        server?.terminate()
        try? FileManager.default.removeItem(at: root)
    }

    func client(password: String = "secreta") -> FTPClient {
        var s = Session(); s.kind = .ftp; s.host = "127.0.0.1"; s.port = 23421; s.username = "test"
        return FTPClient(session: s, passwordOverride: password)
    }

    func testListingParser() {
        let txt = """
        drwxr-xr-x    2 user  group      4096 Nov  2 10:00 mi carpeta
        -rw-r--r--    1 user  group   1234567 Jan 15  2024 informe final.pdf
        lrwxrwxrwx    1 user  group        11 Nov  2 09:15 enlace -> /etc/hosts
        total 3
        """
        let l = FTPClient.parseListing(txt, in: "/x")
        XCTAssertEqual(l.map(\.name), ["mi carpeta", "informe final.pdf", "enlace"])
        XCTAssertTrue(l[0].isDirectory)
        XCTAssertEqual(l[1].size, 1_234_567)
        XCTAssertEqual(l[1].path, "/x/informe final.pdf")
        XCTAssertEqual(l[1].permissionString, "-rw-r--r--")
        XCTAssertTrue(l[2].isSymlink)
        XCTAssertEqual(Calendar.current.component(.year, from: l[1].mtime), 2024)
    }

    func testFullRoundTripAgainstFTPServer() async throws {
        let c = client()
        try await c.connect()
        try await c.mkdir("/docs", mode: 0o755)
        var blob = Data()
        for i in 0..<250_000 { blob.append(UInt8(truncatingIfNeeded: i &* 31 &+ i >> 8)) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("sd-ftp-up-\(UUID().uuidString)")
        try blob.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try await c.upload(local: local, to: "/docs/mi archivo.bin", mode: 0o644) { _, _ in }

        let rootList = try await c.list("/")
        XCTAssertEqual(rootList.map(\.name), ["docs"])
        XCTAssertTrue(rootList[0].isDirectory)
        let docs = try await c.list("/docs")
        XCTAssertEqual(docs.map(\.name), ["mi archivo.bin"], "los nombres con espacios funcionan")
        XCTAssertEqual(docs[0].size, Int64(blob.count))

        let down = FileManager.default.temporaryDirectory.appendingPathComponent("sd-ftp-down-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: down) }
        try await c.download(remote: "/docs/mi archivo.bin", to: down) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: down), blob, "bajada idéntica byte a byte")

        try await c.rename("/docs/mi archivo.bin", to: "/docs/renombrado.bin")
        try await c.chmod("/docs/renombrado.bin", mode: 0o600)
        let st = try await c.stat("/docs/renombrado.bin", followLinks: true)
        XCTAssertEqual(st.permissions & 0o777, 0o600)

        try await c.removeRecursive(try await c.stat("/docs", followLinks: true))
        let after = try await c.list("/")
        XCTAssertTrue(after.isEmpty, "borrado recursivo")
    }

    func testWrongPasswordIsRejected() async throws {
        let c = client(password: "mal")
        do { try await c.connect(); XCTFail("debería rechazar el login") }
        catch SFTPError.status(let code, _) { XCTAssertEqual(code, 3, "login rechazado") }
    }
}
