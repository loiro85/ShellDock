import Foundation

/// Decodificación que rellena con los valores por defecto los campos que faltan en datos guardados por versiones antiguas.
enum TolerantJSON {
    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) throws -> T {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults))
        let stored = try JSONSerialization.jsonObject(with: data)
        let merged = overlay(base, stored)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    /// Los diccionarios se mezclan de forma recursiva: lo guardado manda, lo que falta sale del valor por defecto.
    static func overlay(_ base: Any, _ stored: Any) -> Any {
        guard let b = base as? [String: Any], let s = stored as? [String: Any] else { return stored }
        var out = b
        for (k, v) in s { out[k] = b[k].map { overlay($0, v) } ?? v }
        return out
    }

    /// Lista de elementos: cada uno se decodifica por separado; los ilegibles se descartan en vez de invalidar todo el archivo.
    static func decodeList<T: Codable>(_ type: T.Type, from array: [Any], defaults: T) -> [T] {
        array.compactMap { el in
            guard JSONSerialization.isValidJSONObject(el), let d = try? JSONSerialization.data(withJSONObject: el) else { return nil }
            return try? decode(T.self, from: d, defaults: defaults)
        }
    }

    static func decodeStore(_ data: Data) throws -> StoreData {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        var d = StoreData()
        d.sessions = decodeList(Session.self, from: root["sessions"] as? [Any] ?? [], defaults: Session())
        d.folders = decodeList(Folder.self, from: root["folders"] as? [Any] ?? [], defaults: Folder())
        d.snippets = decodeList(Snippet.self, from: root["snippets"] as? [Any] ?? [], defaults: Snippet())
        d.savedTunnels = decodeList(SavedTunnel.self, from: root["savedTunnels"] as? [Any] ?? [], defaults: SavedTunnel())
        return d
    }
}
