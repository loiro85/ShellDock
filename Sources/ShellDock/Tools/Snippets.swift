import Foundation

/// Expansión y ejecución de snippets/macros.
enum SnippetRunner {
    /// Variables: ${host} ${user} ${session} ${date} ${time} ${clipboard}
    static func expand(_ text: String, session: Session?, now: Date = Date(), clipboard: String = "") -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        var t = text
        let vars: [String: String] = [
            "host": session?.host ?? "", "user": session?.username ?? "", "session": session?.name ?? "",
            "date": df.string(from: now), "time": tf.string(from: now), "clipboard": clipboard,
        ]
        for (k, v) in vars { t = t.replacingOccurrences(of: "${\(k)}", with: v) }
        return t
    }

    enum Step: Equatable {
        case text(String)       // se envía tal cual (con \r si es línea completa)
        case wait(Double)
    }

    /// Convierte el texto del snippet en pasos. Las líneas `#wait N` (segundos) añaden pausas.
    static func steps(_ text: String, sendReturn: Bool) -> [Step] {
        var out: [Step] = []
        let lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("#wait "), let s = Double(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) { out.append(.wait(min(max(s, 0), 600))); continue }
            let last = i == lines.count - 1
            if last && line.isEmpty { continue }
            out.append(.text(line + ((last && !sendReturn) ? "" : "\r")))
        }
        return out
    }
}
