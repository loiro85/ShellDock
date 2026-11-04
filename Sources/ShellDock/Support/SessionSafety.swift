import Foundation

/// Validación de lo que acaba en la línea de órdenes de ssh/curl/etc. Un host que empiece por «-» sería interpretado como
/// una opción (p. ej. `-oProxyCommand=…` ejecutaría un comando local), y los enlaces ssh://, las sesiones importadas y los
/// servidores remotos son entradas no fiables.
enum SessionSafety {
    private static let hostChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%[]"))

    static func hostError(_ h: String) -> String? {
        if h.isEmpty { return "Falta el host" }
        if h.hasPrefix("-") { return "El host no puede empezar por «-»" }
        if h.count > 255 { return "Host demasiado largo" }
        if h.unicodeScalars.contains(where: { !hostChars.contains($0) }) { return "El host contiene caracteres no válidos" }
        return nil
    }

    static func userError(_ u: String) -> String? {
        if u.hasPrefix("-") { return "El usuario no puede empezar por «-»" }
        if u.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) { return "El usuario contiene caracteres no válidos" }
        return nil
    }

    static func jumpError(_ j: String) -> String? {
        let t = j.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if t.hasPrefix("-") || t.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) { return "Salto (ProxyJump) no válido" }
        return nil
    }

    /// Nombre de archivo devuelto por un servidor: no puede escapar de la carpeta de destino.
    static func isSafeRemoteName(_ n: String) -> Bool {
        !(n.isEmpty || n == "." || n == ".." || hasAny(n, ["/", "\0", "\r", "\n"]))
    }

    /// Ruta usada en órdenes FTP: un salto de línea permitiría inyectar otra orden.
    static func isSafeFTPPath(_ p: String) -> Bool { !hasAny(p, ["\r", "\n", "\0"]) }

    /// Se mira por escalares Unicode: en Swift "\r\n" es UN solo Character y `contains("\r")` no lo encontraría.
    private static func hasAny(_ s: String, _ scalars: [Unicode.Scalar]) -> Bool { s.unicodeScalars.contains(where: scalars.contains) }

    static func stripControl(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }))
    }

    /// Host de las herramientas de red (ping, dig…): sin espacios ni «-» inicial.
    static func toolHostError(_ h: String) -> String? {
        let t = h.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Escribe un host" }
        if t.hasPrefix("-") || t.hasPrefix("+") || t.hasPrefix("@") { return "Host no válido" }
        if t.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) { return "Host no válido" }
        return nil
    }
}

extension Session {
    /// Motivo por el que la sesión no debe abrirse (nil = correcta).
    var validationError: String? {
        if kind == .browser {
            let t = host.trimmingCharacters(in: .whitespaces).lowercased()
            if t.contains("://") && !(t.hasPrefix("http://") || t.hasPrefix("https://")) { return "Solo se admiten direcciones http y https" }
            return nil
        }
        guard kind.needsHost else { return nil }
        return SessionSafety.hostError(host) ?? SessionSafety.userError(username) ?? SessionSafety.jumpError(jumpHost)
    }

    /// Sesión recibida de fuera (importación, enlace): se descartan las opciones que ejecutarían algo en este Mac sin que el
    /// usuario las haya escrito (argumentos extra de ssh como -oProxyCommand, carpetas compartidas con la VM).
    func sanitizedForImport() -> Session {
        var s = self
        s.extraArguments = ""
        s.sharedFolder = ""
        s.name = SessionSafety.stripControl(name)
        return s
    }
}
