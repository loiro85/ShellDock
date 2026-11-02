import XCTest
import Darwin
@testable import ShellDock

final class TelnetParserTests: XCTestCase {
    func testNegotiationReplies() {
        var p = TelnetParser()
        let (text, reply, events) = p.feed([255, 253, 24, 255, 253, 31, 255, 251, 1, 255, 253, 99, 104, 105])
        XCTAssertEqual(text, [104, 105], "solo queda el texto 'hi'")
        // DO TTYPE→WILL TTYPE, DO NAWS→WILL NAWS, WILL ECHO→DO ECHO, DO opción-desconocida→WONT
        XCTAssertEqual(reply, [255, 251, 24, 255, 251, 31, 255, 253, 1, 255, 252, 99])
        XCTAssertEqual(events, [.naws(true)])
    }

    func testEscapedIACAndSplitPackets() {
        var p = TelnetParser()
        var all: [UInt8] = []
        for chunk in [[65, 255], [255, 66, 255], [250, 24, 1, 255], [240, 67]] as [[UInt8]] {
            let (t, _, e) = p.feed(chunk)
            all += t
            if !e.isEmpty { XCTAssertEqual(e, [.ttypeRequested]) }
        }
        XCTAssertEqual(all, [65, 255, 66, 67], "IAC IAC es un 0xFF literal; la subnegociación no llega al terminal")
    }
}

@MainActor
final class TransportTests: XCTestCase {
    func waitFor(_ timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return cond()
    }

    func startPython(_ script: String) throws -> (Process, URL) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sd-srv-\(UUID().uuidString).py")
        try script.write(to: f, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", f.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let line = out.fileHandleForReading.availableData
        XCTAssertTrue(String(decoding: line, as: UTF8.self).contains("READY"), "servidor de pruebas listo")
        return (p, f)
    }

    func testTelnetNegotiationAndEcho() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("sd-telnet-\(UUID().uuidString).log")
        let (srv, file) = try startPython("""
        import socket
        IAC,DO,WILL,SB,SE=255,253,251,250,240
        s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',23231)); s.listen(1)
        print('READY',flush=True)
        c,_=s.accept()
        c.sendall(bytes([IAC,DO,24,IAC,DO,31,IAC,WILL,1])+b'Bienvenido\\r\\n'+bytes([IAC,SB,24,1,IAC,SE]))
        while True:
            d=c.recv(4096)
            if not d: break
            open('\(log.path)','ab').write(d)
            if b'\\n' in d: c.sendall(b'ECO:'+d.replace(b'\\r',b'').replace(b'\\n',b'')+b'\\r\\n')
        """)
        defer { srv.terminate(); try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: log) }

        let t = TelnetTransport(host: "127.0.0.1", port: 23231)
        var received: [UInt8] = []
        t.onData = { received += $0 }
        t.open()
        let okBanner = await waitFor { String(decoding: received, as: UTF8.self).contains("Bienvenido") }
        XCTAssertTrue(okBanner, "recibe el banner sin bytes IAC")
        XCTAssertFalse(received.contains(255))
        t.resize(cols: 100, rows: 30)
        t.send(Array("hola\r".utf8))
        let okEcho = await waitFor { String(decoding: received, as: UTF8.self).contains("ECO:hola") }
        XCTAssertTrue(okEcho, "el servidor recibió 'hola' con CRLF y respondió")
        t.close()

        let raw = (try? Data(contentsOf: log)) ?? Data()
        let bytes = [UInt8](raw)
        func has(_ needle: [UInt8]) -> Bool { bytes.windows(ofCount: needle.count).contains { Array($0) == needle } }
        XCTAssertTrue(has([255, 251, 24]), "WILL TTYPE")
        XCTAssertTrue(has([255, 251, 31]), "WILL NAWS")
        XCTAssertTrue(has([255, 253, 1]), "DO ECHO")
        XCTAssertTrue(has([255, 250, 24, 0] + Array("xterm-256color".utf8) + [255, 240]), "tipo de terminal enviado")
        XCTAssertTrue(has([255, 250, 31, 0, 100, 0, 30, 255, 240]), "tamaño 100x30 (NAWS)")
    }

    func testRawTCPRoundTrip() async throws {
        let (srv, file) = try startPython("""
        import socket
        s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',23232)); s.listen(1)
        print('READY',flush=True)
        c,_=s.accept()
        c.sendall(b'HOLA-TCP\\n')
        while True:
            d=c.recv(4096)
            if not d: break
            c.sendall(d.upper())
        """)
        defer { srv.terminate(); try? FileManager.default.removeItem(at: file) }
        let t = TCPTransport(host: "127.0.0.1", port: 23232)
        var got: [UInt8] = []
        t.onData = { got += $0 }
        t.open()
        let ok1 = await waitFor { String(decoding: got, as: UTF8.self).contains("HOLA-TCP") }
        XCTAssertTrue(ok1)
        t.send(Array("ping".utf8))
        let ok2 = await waitFor { String(decoding: got, as: UTF8.self).contains("PING") }
        XCTAssertTrue(ok2, "eco en mayúsculas")
        var closed = false
        t.onClose = { _ in closed = true }
        srv.terminate()
        let ok3 = await waitFor { closed }
        XCTAssertTrue(ok3, "detecta que el servidor cerró")
    }

    func testSerialOverPseudoTerminal() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        let dev = String(cString: name)
        var s = SerialSettings()
        s.device = dev
        s.baud = 9600
        let t = SerialTransport(settings: s)
        var got: [UInt8] = []
        var opened = false
        t.onOpen = { opened = true }
        t.onData = { got += $0 }
        t.open()
        XCTAssertTrue(opened, "abre \(dev)")
        _ = "DATOS-SERIE".withCString { write(master, $0, 11) }
        let ok = await waitFor { String(decoding: got, as: UTF8.self).contains("DATOS-SERIE") }
        XCTAssertTrue(ok, "lee lo que escribe el dispositivo")
        t.send(Array("AT\r".utf8))
        var buf = [UInt8](repeating: 0, count: 16)
        try await Task.sleep(nanoseconds: 200_000_000)
        let fl = fcntl(master, F_GETFL); _ = fcntl(master, F_SETFL, fl | O_NONBLOCK)
        let n = read(master, &buf, 16)
        XCTAssertEqual(String(decoding: buf[0..<max(n, 0)], as: UTF8.self), "AT\r", "el dispositivo recibe lo que se teclea")
        var tio = termios(); tcgetattr(slave, &tio)
        XCTAssertEqual(cfgetospeed(&tio), 9600, "baudios aplicados")
        t.close()
    }
}

extension Array {
    func windows(ofCount n: Int) -> [ArraySlice<Element>] {
        guard n > 0, count >= n else { return [] }
        return (0...(count - n)).map { self[$0..<($0 + n)] }
    }
}
