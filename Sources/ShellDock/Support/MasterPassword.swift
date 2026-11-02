import Foundation
import CommonCrypto
import Security

/// Contraseña maestra opcional: bloquea la ventana al abrir la app. Se guarda como PBKDF2-SHA256 con sal en el Llavero.
enum MasterPassword {
    private static let account = "master-password"

    static var isSet: Bool { Keychain.get(account: account) != nil }

    static func set(_ password: String) {
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        Keychain.set(hex(salt) + ":" + hex(derive(password, salt: salt)), account: account)
    }

    static func remove() { Keychain.delete(account: account) }

    static func verify(_ password: String) -> Bool {
        guard let stored = Keychain.get(account: account) else { return true }
        let p = stored.split(separator: ":")
        guard p.count == 2, let salt = bytes(String(p[0])) else { return false }
        let a = hex(derive(password, salt: salt)), b = String(p[1])
        return a.count == b.count && zip(a.utf8, b.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0     // tiempo constante
    }

    static func derive(_ password: String, salt: [UInt8], rounds: UInt32 = 200_000) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        return out
    }

    private static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private static func bytes(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8](), i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); guard let b = UInt8(s[i..<j], radix: 16) else { return nil }; out.append(b); i = j }
        return out
    }
}
