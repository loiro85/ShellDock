import Foundation
import CryptoKit
import Security

/// Utilidades de administración de sistemas (lógica pura, probada).
enum Utilities {
    // MARK: contraseñas

    static func password(length: Int, upper: Bool = true, lower: Bool = true, digits: Bool = true, symbols: Bool = true) -> String {
        var sets: [[Character]] = []
        if upper { sets.append(Array("ABCDEFGHJKLMNPQRSTUVWXYZ")) }
        if lower { sets.append(Array("abcdefghijkmnopqrstuvwxyz")) }
        if digits { sets.append(Array("23456789")) }
        if symbols { sets.append(Array("!@#$%^&*()-_=+[]{};:,.?")) }
        guard !sets.isEmpty, length > 0 else { return "" }
        let all = sets.flatMap { $0 }
        var out: [Character] = sets.prefix(length).map { $0[randomIndex($0.count)] }      // al menos uno de cada tipo
        while out.count < length { out.append(all[randomIndex(all.count)]) }
        for i in stride(from: out.count - 1, to: 0, by: -1) { out.swapAt(i, randomIndex(i + 1)) }
        return String(out)
    }

    private static func randomIndex(_ n: Int) -> Int {
        var v: UInt32 = 0
        repeat { _ = SecRandomCopyBytes(kSecRandomDefault, 4, &v) } while v >= UInt32.max - UInt32.max % UInt32(n)   // sin sesgo
        return Int(v % UInt32(n))
    }

    // MARK: hashes y codificaciones

    static func hashes(of data: Data) -> [(String, String)] {
        func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
        return [("MD5", hex(Insecure.MD5.hash(data: data))), ("SHA-1", hex(Insecure.SHA1.hash(data: data))),
                ("SHA-256", hex(SHA256.hash(data: data))), ("SHA-512", hex(SHA512.hash(data: data)))]
    }

    static func base64Encode(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    static func base64Decode(_ s: String) -> String? {
        Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func urlEncode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }
    static func urlDecode(_ s: String) -> String { s.removingPercentEncoding ?? s }
    static func hexEncode(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined(separator: " ") }
    static func hexDecode(_ s: String) -> String? {
        let clean = s.filter { !$0.isWhitespace }
        guard clean.allSatisfy({ $0.isHexDigit }), clean.count % 2 == 0 else { return nil }
        var bytes = [UInt8](), i = clean.startIndex
        while i < clean.endIndex { let j = clean.index(i, offsetBy: 2); guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }; bytes.append(b); i = j }
        return String(bytes: bytes, encoding: .utf8)
    }

    // MARK: subredes IPv4

    struct Subnet: Equatable {
        var network, broadcast, mask, wildcard, first, last: String
        var hosts: UInt64
    }

    static func subnet(_ cidr: String) -> Subnet? {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix), let ip = ipv4(String(parts[0])) else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        let net = ip & mask, bc = net | ~mask
        let hosts: UInt64 = prefix >= 31 ? UInt64(1) << UInt64(32 - prefix) : (UInt64(1) << UInt64(32 - prefix)) - 2
        let (f, l) = prefix >= 31 ? (net, bc) : (net + 1, bc - 1)
        return Subnet(network: str(net), broadcast: str(bc), mask: str(mask), wildcard: str(~mask), first: str(f), last: str(l), hosts: hosts)
    }

    private static func ipv4(_ s: String) -> UInt32? {
        let p = s.split(separator: ".").compactMap { UInt32($0) }
        guard p.count == 4, p.allSatisfy({ $0 < 256 }) else { return nil }
        return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]
    }
    private static func str(_ v: UInt32) -> String { "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)" }

    // MARK: fecha Unix

    static func epochToDate(_ s: String) -> String? {
        guard var v = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
        if v > 1e12 { v /= 1000 }                      // milisegundos
        let d = Date(timeIntervalSince1970: v)
        let f = ISO8601DateFormatter(); f.timeZone = .current
        return f.string(from: d) + "  (UTC: " + ISO8601DateFormatter().string(from: d) + ")"
    }
}
