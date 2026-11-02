import Foundation

/// Importa sesiones de un fichero `.mxtsessions` exportado de MobaXterm (formato INI; mejor esfuerzo).
enum MobaImporter {
    static func looksLikeMoba(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return false }
        return s.contains("[Bookmarks") && s.contains("SubRep=")
    }

    @MainActor
    static func importSessions(_ data: Data, into store: SessionStore) -> Int {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var section = ""
        var subrep = ""
        var count = 0
        var folderCache: [String: UUID] = [:]

        func folder(for path: String) -> UUID? {
            let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            var parent: UUID? = nil
            var key = ""
            for p in parts {
                key += "/" + p
                if let id = folderCache[key] { parent = id; continue }
                if let existing = store.folders.first(where: { $0.name == p && $0.parentID == parent }) {
                    folderCache[key] = existing.id; parent = existing.id; continue
                }
                let f = Folder(name: p, parentID: parent)
                store.upsert(folder: f)
                folderCache[key] = f.id
                parent = f.id
            }
            return parent
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); subrep = ""; continue }
            guard section.hasPrefix("Bookmarks"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            if key == "SubRep" { subrep = value; continue }
            if key == "ImgNum" { continue }
            guard value.hasPrefix("#") else { continue }
            if let s = parse(name: key, value: value, folderID: folder(for: subrep)) { store.upsert(session: s); count += 1 }
        }
        return count
    }

    /// `#109#0%host%22%usuario%...` → sesión
    static func parse(name: String, value: String, folderID: UUID?) -> Session? {
        let parts = value.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        let typeNum = Int(parts[1]) ?? 109
        let fields = parts[2].split(separator: "%", omittingEmptySubsequences: false).map(String.init)
        var s = Session()
        s.name = name
        s.folderID = folderID
        switch typeNum {
        case 91: s.kind = .rdp
        case 128: s.kind = .vnc
        case 98: s.kind = .telnet
        case 140: s.kind = .sftp
        case 100: s.kind = .ftp
        default: s.kind = .ssh
        }
        guard fields.count > 3 else { return nil }
        s.host = fields[1]
        s.port = Int(fields[2]) ?? s.kind.defaultPort
        if s.port == 0 { s.port = s.kind.defaultPort }
        s.username = fields[3]
        return s.host.isEmpty ? nil : s
    }
}
