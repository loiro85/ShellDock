import XCTest
@testable import ShellDock

final class SFTPTests: XCTestCase {
    func connect() async throws -> SFTPClient {
        let s = TestServer.session()
        let c = SFTPClient()
        try await c.start(executable: SSHLauncher.sshPath, arguments: SSHLauncher.sftpSubsystemArguments(s, hostKeyPolicy: "no"), environment: SSHLauncher.environment(for: s))
        return c
    }

    func testFullRoundTrip() async throws {
        try TestServer.skipIfUnavailable()
        let c = try await connect()
        defer { c.close() }

        let home = try await c.realpath(".")
        XCTAssertTrue(home.hasPrefix("/"), "ruta absoluta: \(home)")

        let base = home + "/sd-sftp-test-\(UUID().uuidString.prefix(8))"
        try await c.mkdir(base)
        var st = try await c.stat(base)
        XCTAssertTrue(st.isDirectory)

        // subir un fichero de ~1,5 MB con contenido conocido (varios bloques en paralelo)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("sd-up-\(UUID().uuidString)")
        var blob = Data()
        for i in 0..<(1_500_000 / 4) { var v = UInt32(truncatingIfNeeded: i &* 2654435761); blob.append(Data(bytes: &v, count: 4)) }
        try blob.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        var lastProgress: Int64 = 0
        try await c.upload(local: local, to: base + "/datos.bin") { done, _ in lastProgress = max(lastProgress, done) }
        XCTAssertEqual(lastProgress, Int64(blob.count))

        let list = try await c.list(base)
        XCTAssertEqual(list.map(\.name), ["datos.bin"])
        XCTAssertEqual(list[0].size, Int64(blob.count))
        XCTAssertFalse(list[0].isDirectory)

        // bajar y comparar byte a byte
        let down = FileManager.default.temporaryDirectory.appendingPathComponent("sd-down-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: down) }
        try await c.download(remote: base + "/datos.bin", to: down)
        XCTAssertEqual(try Data(contentsOf: down), blob, "el contenido descargado coincide")

        // renombrar y permisos
        try await c.rename(base + "/datos.bin", to: base + "/renombrado.bin")
        try await c.chmod(base + "/renombrado.bin", mode: 0o600)
        st = try await c.stat(base + "/renombrado.bin")
        XCTAssertEqual(st.permissions & 0o7777, 0o600)
        XCTAssertEqual(st.permissionString, "-rw-------")

        // leer / escribir texto
        try await c.writeFile(Data("hola ñandú ✓\n".utf8), to: base + "/nota.txt")
        let txt = String(decoding: try await c.readFile(base + "/nota.txt"), as: UTF8.self)
        XCTAssertEqual(txt, "hola ñandú ✓\n")

        // subdirectorios y borrado recursivo
        try await c.mkdir(base + "/sub")
        try await c.writeFile(Data("x".utf8), to: base + "/sub/dentro.txt")
        let root = try await c.stat(base)
        try await c.removeRecursive(root)
        do { _ = try await c.stat(base); XCTFail("debería haberse borrado") }
        catch SFTPError.status(let code, _) { XCTAssertEqual(code, 2, "NO_SUCH_FILE") }
    }

    func testErrorsAreReported() async throws {
        try TestServer.skipIfUnavailable()
        let c = try await connect()
        defer { c.close() }
        do { _ = try await c.list("/no/existe/seguro"); XCTFail() }
        catch SFTPError.status(let code, _) { XCTAssertEqual(code, 2) }
        do { try await c.mkdir("/proc-no-permitido/x"); XCTFail() }
        catch SFTPError.status(let code, _) { XCTAssertTrue(code == 2 || code == 3 || code == 4) }
    }

    func testPermissionString() {
        let f = RemoteFile(name: "x", path: "/x", size: 0, permissions: 0o104755, mtime: Date(), uid: 0, gid: 0)
        XCTAssertEqual(f.permissionString, "-rwsr-xr-x")
        let d = RemoteFile(name: "d", path: "/d", size: 0, permissions: 0o041777, mtime: Date(), uid: 0, gid: 0)
        XCTAssertEqual(d.permissionString, "drwxrwxrwt")
    }
}
