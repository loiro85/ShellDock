import XCTest
@testable import ShellDock

final class VNCTests: XCTestCase {
    private func launch(mode: String, port: Int) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/rfbserver.py").path
        p.arguments = [path, String(port), mode]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        _ = out.fileHandleForReading.availableData      // "ready"
        return p
    }

    private func run(mode: String, port: Int, password: String?) throws -> RFBClient {
        let p = try launch(mode: mode, port: port)
        addTeardownBlock { p.terminate() }
        let c = RFBClient()
        try c.connect(host: "127.0.0.1", port: port, password: password)
        return c
    }

    private func waitPixel(_ c: RFBClient, x: Int, y: Int, _ rgb: (UInt8, UInt8, UInt8)) -> Bool {
        for _ in 0..<50 {
            let px = c.pixel(x: x, y: y)
            if (px.r, px.g, px.b) == rgb { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    func testNoneSecurityAndEncodings() throws {
        let c = try run(mode: "none", port: 25901, password: nil)
        XCTAssertEqual(c.width, 64); XCTAssertEqual(c.height, 32); XCTAssertEqual(c.name, "fake")
        XCTAssertTrue(waitPixel(c, x: 11, y: 6, (0, 255, 0)), "subrect Hextile verde")
        let bg = c.pixel(x: 40, y: 20)
        XCTAssertEqual([bg.r, bg.g, bg.b], [0, 0, 255])   // fondo azul (el Raw rojo se pisa después)
        XCTAssertNotNil(c.makeImage())
        c.close()
    }

    func testVNCAuthCorrectAndWrong() throws {
        let ok = try run(mode: "auth", port: 25902, password: "secret")
        XCTAssertTrue(waitPixel(ok, x: 11, y: 6, (0, 255, 0)))
        ok.close()
        XCTAssertThrowsError(try run(mode: "auth", port: 25903, password: "wrong")) {
            guard case RFBClient.RFBError.authFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try run(mode: "auth", port: 25904, password: nil)) {
            guard case RFBClient.RFBError.needsPassword = $0 else { return XCTFail("\($0)") }
        }
    }
}
