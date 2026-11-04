import Foundation
import AppKit

/// Datos de ejemplo para capturas (`--demo`). No se guardan en disco.
@MainActor
enum DemoData {
    static func populate(_ s: AppState) {
        let prod = Folder(name: "Production")
        let lab = Folder(name: "Lab")
        let web = Folder(name: "Web", parentID: prod.id)
        for f in [prod, lab, web] { s.store.folders.append(f) }
        func add(_ n: String, _ k: SessionKind, _ h: String, _ u: String, _ f: UUID?, _ c: String? = nil) {
            var x = Session(); x.name = n; x.kind = k; x.host = h; x.username = u; x.folderID = f; x.colorHex = c; x.port = k.defaultPort
            s.store.sessions.append(x)
        }
        add("Bastion", .ssh, "bastion.example.com", "admin", prod.id, "#ff6b6b")
        add("Database", .ssh, "db1.example.com", "dba", prod.id, "#ff9f43")
        add("Nginx 1", .ssh, "web1.example.com", "deploy", web.id, "#7ee787")
        add("Nginx 2", .ssh, "web2.example.com", "deploy", web.id, "#7ee787")
        add("Router", .telnet, "192.168.1.1", "", lab.id)
        add("Remote desktop", .rdp, "10.0.0.20", "administrator", lab.id)
        add("VNC viewer", .vnc, "10.0.0.30", "", lab.id)
        s.openLocal()
        if ProcessInfo.processInfo.environment["SHELLDOCK_DEMO_MULTI"] != nil {
            s.openLocal(); s.openLocal()
            s.multiExec = true
            s.tabs.last?.excluded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if ProcessInfo.processInfo.environment["SHELLDOCK_DEMO_MULTI"] == "keys", let t = s.tabs.first as? ProcessTab {
                    // pulsaciones reales: se encolan en NSApp y recorren el mismo camino que el teclado físico
                    NSApp.activate(ignoringOtherApps: true)
                    t.tv.window?.makeFirstResponder(t.tv)
                    for ch in "echo teclas-$$\r" {
                        let str = String(ch)
                        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: t.tv.window?.windowNumber ?? 0, context: nil, characters: str,
                                                    charactersIgnoringModifiers: str, isARepeat: false, keyCode: ch == "\r" ? 36 : 0) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                } else if ProcessInfo.processInfo.environment["SHELLDOCK_DEMO_MULTI"] == "typing", let t = s.tabs.first as? ProcessTab {
                    // equivale a teclear en la primera terminal
                    t.tv.send(source: t.tv, data: Array("echo tecleado-$$\r".utf8)[...])
                } else { s.send("echo escrito-en-todas-$$\r", toAll: true) }
            }
        }
    }
}
