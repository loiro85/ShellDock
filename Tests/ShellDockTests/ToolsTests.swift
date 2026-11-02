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
