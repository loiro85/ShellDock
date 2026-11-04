import Foundation
import Network
import UniformTypeIdentifiers

/// Servidor HTTP de solo lectura que publica una carpeta (útil para pasar archivos a otras máquinas).
@MainActor
final class HTTPFileServer: ObservableObject {
    @Published var running = false
    @Published var port: UInt16 = 0
    @Published var log: [String] = []
    private var listener: NWListener?
    private var root = URL(fileURLWithPath: "/")

    /// `localOnly`: solo accesible desde este Mac (127.0.0.1). Sin autenticación, publicar en la red es una decisión explícita.
    func start(folder: URL, port: UInt16, localOnly: Bool = true) throws {
        stop()
        root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let params = NWParameters.tcp
        if localOnly { params.requiredInterfaceType = .loopback }
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        l.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .ready: self.running = true; self.port = l.port?.rawValue ?? port
                case .failed(let e): self.running = false; self.log.append("Error: \(e.localizedDescription)")
                default: break
                }
            }
        }
        let rootCopy = root
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .global())
            Self.serve(c, root: rootCopy) { line in Task { @MainActor in self?.log.append(line); if (self?.log.count ?? 0) > 300 { self?.log.removeFirst(100) } } }
        }
        l.start(queue: .global())
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil; running = false }

    // MARK: protocolo

    nonisolated static func serve(_ c: NWConnection, root: URL, log: @escaping (String) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
            guard let data, let req = String(data: data, encoding: .utf8), let first = req.split(separator: "\r\n").first else { c.cancel(); return }
            let parts = first.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
                send(c, status: "405 Method Not Allowed", type: "text/plain", body: Data("405".utf8)); return
            }
            let (status, type, body) = response(for: String(parts[1]), root: root)
            log("\(parts[0]) \(parts[1]) → \(status.prefix(3))")
            send(c, status: status, type: type, body: parts[0] == "HEAD" ? Data() : body, length: body.count)
        }
    }

    nonisolated static func send(_ c: NWConnection, status: String, type: String, body: Data, length: Int? = nil) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length ?? body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// Resuelve la ruta pedida dentro de `root`; rechaza cualquier intento de salirse de la carpeta.
    nonisolated static func response(for target: String, root: URL) -> (String, String, Data) {
        let raw = target.split(separator: "?").first.map(String.init) ?? "/"
        guard let decoded = raw.removingPercentEncoding else { return ("400 Bad Request", "text/plain", Data("400".utf8)) }
        let url = root.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { return ("403 Forbidden", "text/plain", Data("403".utf8)) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return ("404 Not Found", "text/plain", Data("404".utf8)) }
        if isDir.boolValue {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
            let base = decoded.hasSuffix("/") ? decoded : decoded + "/"
            let items = names.map { n -> String in
                let esc = n.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                let href = (base + n).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? n
                return "<li><a href=\"\(href)\">\(esc)</a></li>"
            }.joined()
            let html = "<!doctype html><meta charset=utf-8><title>\(decoded)</title><h1>\(decoded.replacingOccurrences(of: "<", with: "&lt;"))</h1><ul>\(items)</ul>"
            return ("200 OK", "text/html; charset=utf-8", Data(html.utf8))
        }
        guard let data = try? Data(contentsOf: url) else { return ("403 Forbidden", "text/plain", Data("403".utf8)) }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ("200 OK", type, data)
    }
}
