import Foundation

/// Idiomas de la interfaz. El idioma predeterminado es el inglés; las cadenas del código están escritas en español y sirven
/// de clave (es.lproj es la identidad); el resto de idiomas están en Resources/Localization/<código>.lproj.
enum Loc {
    struct Language: Identifiable, Hashable { let code: String; let name: String; var id: String { code } }

    static let languages: [Language] = [
        .init(code: "en", name: "English"), .init(code: "es", name: "Español"), .init(code: "fr", name: "Français"),
        .init(code: "it", name: "Italiano"), .init(code: "de", name: "Deutsch"), .init(code: "pt", name: "Português"),
    ]
    static let defaultCode = "en"

    nonisolated(unsafe) private static var bundle: Bundle = Bundle.main
    nonisolated(unsafe) private(set) static var code = defaultCode

    /// Cambia el idioma de las cadenas obtenidas con `tr`. Devuelve el código realmente aplicado.
    @discardableResult
    static func set(_ requested: String, resourceBundle: Bundle = .main) -> String {
        let c = languages.contains { $0.code == requested } ? requested : defaultCode
        code = c
        if let path = resourceBundle.path(forResource: c, ofType: "lproj"), let b = Bundle(path: path) { bundle = b } else { bundle = resourceBundle }
        return c
    }

    static var locale: Locale { Locale(identifier: code) }

    static func lookup(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: nil) }
}

/// Texto de interfaz de tipo String (avisos, alertas, etiquetas calculadas). Los argumentos sustituyen a cada «%@», en orden.
func tr(_ key: String, _ args: String...) -> String {
    let text = Loc.lookup(key)
    guard !args.isEmpty else { return text }
    var out = "", rest = args[...]
    var i = text.startIndex
    while i < text.endIndex {
        if text[i...].hasPrefix("%@"), let a = rest.first { out += a; rest = rest.dropFirst(); i = text.index(i, offsetBy: 2) }
        else if text[i...].hasPrefix("%1$@") || text[i...].hasPrefix("%2$@") || text[i...].hasPrefix("%3$@") || text[i...].hasPrefix("%4$@") {
            let n = Int(String(text[text.index(i, offsetBy: 1)])) ?? 1
            if n >= 1, n <= args.count { out += args[n - 1] }
            i = text.index(i, offsetBy: 4)
        } else { out.append(text[i]); i = text.index(after: i) }
    }
    return out
}
