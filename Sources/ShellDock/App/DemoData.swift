import Foundation

/// Datos de ejemplo para capturas (`--demo`). No se guardan en disco.
@MainActor
enum DemoData {
    static func populate(_ s: AppState) {
        let prod = Folder(name: "Producción")
        let lab = Folder(name: "Laboratorio")
        let web = Folder(name: "Web", parentID: prod.id)
        for f in [prod, lab, web] { s.store.folders.append(f) }
        func add(_ n: String, _ k: SessionKind, _ h: String, _ u: String, _ f: UUID?, _ c: String? = nil) {
            var x = Session(); x.name = n; x.kind = k; x.host = h; x.username = u; x.folderID = f; x.colorHex = c; x.port = k.defaultPort
            s.store.sessions.append(x)
        }
        add("Bastión", .ssh, "bastion.example.com", "admin", prod.id, "#ff6b6b")
        add("Base de datos", .ssh, "db1.example.com", "dba", prod.id, "#ff9f43")
        add("Nginx 1", .ssh, "web1.example.com", "deploy", web.id, "#7ee787")
        add("Nginx 2", .ssh, "web2.example.com", "deploy", web.id, "#7ee787")
        add("Router", .telnet, "192.168.1.1", "", lab.id)
        add("Escritorio remoto", .rdp, "10.0.0.20", "administrador", lab.id)
        add("Visor VNC", .vnc, "10.0.0.30", "", lab.id)
        s.openLocal()
    }
}
