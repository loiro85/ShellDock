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
