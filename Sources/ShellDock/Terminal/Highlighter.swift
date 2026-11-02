import Foundation

/// Resaltado de palabras clave en la salida de texto plano (útil en servidores sin color) y utilidades de macros.
enum KeywordHighlighter {
    private static let rules: [(NSRegularExpression, String)] = {
        func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
        return [
            (rx("\\b(error|errors|fail|failed|failure|fatal|critical|denied|refused|panic|exception|segfault|unreachable)\\b"), "1;31"),
            (rx("\\b(warn|warning|deprecated|timeout|timed out|retry)\\b"), "33"),
            (rx("\\b(ok|success|successful|succeeded|passed|done|started|running|active|up)\\b"), "32"),
            (rx("\\b(info|notice|debug)\\b"), "36"),
            (rx("\\b\\d{1,3}(?:\\.\\d{1,3}){3}\\b"), "35"),
        ]
    }()

    /// Devuelve los mismos bytes con secuencias SGR añadidas. Si el fragmento contiene otras secuencias de control
    /// (pantalla completa, cursor…) se devuelve intacto para no estropear aplicaciones como vim o top.
    static func process(_ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty, bytes.count < 65_536 else { return bytes }
        guard let text = String(validatingUTF8: bytes.map { CChar(bitPattern: $0) } + [0]) else { return bytes }
        // solo se acepta ESC [ … m
        var i = text.startIndex
        while let esc = text[i...].firstIndex(of: "\u{1b}") {
            let rest = text[text.index(after: esc)...]
            guard rest.first == "[" else { return bytes }
            guard let end = rest.firstIndex(where: { $0.isLetter || "~@`".contains($0) }), rest[end] == "m" else { return bytes }
            i = rest.index(after: end)
        }
        // se resalta únicamente el texto fuera de las secuencias SGR existentes
        var out = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "\u{1b}", let m = text[cursor...].firstIndex(of: "m") {
                let next = text.index(after: m)
                out += text[cursor..<next]; cursor = next; continue
            }
            let stop = text[cursor...].firstIndex(of: "\u{1b}") ?? text.endIndex
            out += highlight(String(text[cursor..<stop]))
            cursor = stop
        }
        return Array(out.utf8)
    }

    static func highlight(_ s: String) -> String {
        let ns = s as NSString
        var marks: [(NSRange, String)] = []
        for (re, code) in rules {
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                if !marks.contains(where: { NSIntersectionRange($0.0, m.range).length > 0 }) { marks.append((m.range, code)) }
            }
        }
        guard !marks.isEmpty else { return s }
        var out = "", pos = 0
        for (r, code) in marks.sorted(by: { $0.0.location < $1.0.location }) {
            out += ns.substring(with: NSRange(location: pos, length: r.location - pos))
            out += "\u{1b}[\(code)m" + ns.substring(with: r) + "\u{1b}[0m"
            pos = r.location + r.length
        }
        return out + ns.substring(from: pos)
    }
}

/// Convierte lo tecleado durante una grabación en el texto de una macro (una línea por Intro).
enum MacroRecorder {
    static func text(from bytes: [UInt8]) -> String {
        var line: [Character] = []
        var lines: [String] = []
        var i = 0
        let s = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        while i < s.count {
            let c = s[i]
            switch c.value {
            case 0x0D, 0x0A: lines.append(String(line)); line = []
            case 0x7F, 0x08: if !line.isEmpty { line.removeLast() }
            case 0x1B:      // se descarta la secuencia de escape (flechas, etc.)
                i += 1
                if i < s.count, s[i] == "[" || s[i] == "O" {
                    i += 1
                    while i < s.count, !(s[i].properties.isAlphabetic || s[i] == "~") { i += 1 }
                }
            case 0x09: line.append("\t")
            case 0..<0x20: break
            default: line.append(Character(c))
            }
            i += 1
        }
        if !line.isEmpty { lines.append(String(line)) }
        return lines.joined(separator: "\n")
    }
}
