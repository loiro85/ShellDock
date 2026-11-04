import Foundation
import Combine

struct StoreData: Codable {
    var sessions: [Session] = []
    var folders: [Folder] = []
    var snippets: [Snippet] = []
    var savedTunnels: [SavedTunnel] = []
    var version = 1
}

/// Almacén persistente de sesiones, carpetas, snippets y túneles. Sin ningún límite de cantidad.
@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var folders: [Folder] = []
    @Published var snippets: [Snippet] = []
    @Published var savedTunnels: [SavedTunnel] = []

    private let url: URL
    private var cancellable: AnyCancellable?
    private var loading = false

    init(url: URL = Paths.sessionsFile) {
        self.url = url
        load()
        // guardado automático con pequeño retardo
        cancellable = objectWillChange
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
    }

    // MARK: persistencia

    func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: url) else { return }
        guard let d = try? TolerantJSON.decodeStore(data) else {
            // archivo ilegible: se conserva una copia para no perder nada al guardar de nuevo
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent().appendingPathComponent("sessions.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("ShellDock: sessions.json ilegible; copia en \(backup.path)")
            return
        }
        sessions = d.sessions
        folders = d.folders
        snippets = d.snippets
        savedTunnels = d.savedTunnels
    }

    func save() {
        guard !loading else { return }
        let d = StoreData(sessions: sessions, folders: folders, snippets: snippets, savedTunnels: savedTunnels)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(d) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)     // nombres de host y usuarios: solo el propietario
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            NSLog("ShellDock: no se pudo guardar: \(error)")
        }
    }

    /// Exporta todo (sin contraseñas) como JSON.
    func exportData() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(StoreData(sessions: sessions, folders: folders, snippets: snippets, savedTunnels: savedTunnels))
    }

    /// Importa un JSON exportado (fusiona; los ids existentes se reemplazan).
    @discardableResult
    func importData(_ data: Data) -> Int {
        guard let d = try? TolerantJSON.decodeStore(data) else { return 0 }
        for f in d.folders { upsert(folder: f) }
        for s in d.sessions { upsert(session: s.sanitizedForImport()) }
        for s in d.snippets where !snippets.contains(where: { $0.id == s.id }) { snippets.append(s) }
        for t in d.savedTunnels where !savedTunnels.contains(where: { $0.id == t.id }) { savedTunnels.append(t) }
        return d.sessions.count
    }

    // MARK: sesiones

    func upsert(session: Session) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session } else { sessions.append(session) }
    }

    func upsert(folder: Folder) {
        if let i = folders.firstIndex(where: { $0.id == folder.id }) { folders[i] = folder } else { folders.append(folder) }
    }

    func delete(session id: UUID) {
        Keychain.delete(account: id.uuidString)
        Keychain.delete(account: id.uuidString + ".passphrase")
        sessions.removeAll { $0.id == id }
    }

    func duplicate(session id: UUID) -> Session? {
        guard var s = sessions.first(where: { $0.id == id }) else { return nil }
        s.id = UUID()
        s.name += " (copia)"
        s.hasStoredPassword = false
        s.hasStoredPassphrase = false
        sessions.append(s)
        return s
    }

    /// Borra una carpeta; su contenido pasa a la carpeta padre.
    func delete(folder id: UUID) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        for i in sessions.indices where sessions[i].folderID == id { sessions[i].folderID = f.parentID }
        for i in folders.indices where folders[i].parentID == id { folders[i].parentID = f.parentID }
        folders.removeAll { $0.id == id }
    }

    func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }

    func setPassword(_ pw: String, for session: inout Session) {
        if pw.isEmpty {
            Keychain.delete(account: session.id.uuidString)
            session.hasStoredPassword = false
        } else {
            Keychain.set(pw, account: session.id.uuidString)
            session.hasStoredPassword = true
        }
    }

    func setPassphrase(_ pw: String, for session: inout Session) {
        let acc = session.id.uuidString + ".passphrase"
        if pw.isEmpty { Keychain.delete(account: acc); session.hasStoredPassphrase = false }
        else { Keychain.set(pw, account: acc); session.hasStoredPassphrase = true }
    }

    // MARK: árbol

    func childFolders(of parent: UUID?) -> [Folder] {
        folders.filter { $0.parentID == parent }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func childSessions(of parent: UUID?) -> [Session] {
        sessions.filter { $0.folderID == parent }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func search(_ q: String) -> [Session] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return [] }
        return sessions.filter {
            $0.name.lowercased().contains(t) || $0.host.lowercased().contains(t)
                || $0.username.lowercased().contains(t) || $0.notes.lowercased().contains(t)
                || $0.kind.title.lowercased().contains(t)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func folderPath(_ id: UUID?) -> String {
        var parts: [String] = []
        var cur = id
        var guardCount = 0
        while let c = cur, let f = folders.first(where: { $0.id == c }), guardCount < 64 {
            parts.insert(f.name, at: 0)
            cur = f.parentID
            guardCount += 1
        }
        return parts.joined(separator: " / ")
    }
}
