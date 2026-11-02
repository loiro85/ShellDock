import Foundation

enum ShellSplit {
    /// Divide una línea en argumentos respetando comillas simples/dobles y escapes con barra invertida.
    static func split(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character? = nil
        var esc = false
        var has = false
        for ch in line {
            if esc { cur.append(ch); esc = false; has = true; continue }
            if ch == "\\" && quote != "'" { esc = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                has = true
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; has = true; continue }
            if ch == " " || ch == "\t" || ch == "\n" {
                if has { out.append(cur); cur = ""; has = false }
                continue
            }
            cur.append(ch); has = true
        }
        if has { out.append(cur) }
        return out
    }

    /// Entrecomilla un argumento para una shell POSIX.
    static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%_+=:,./-"))
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
