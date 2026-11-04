import SwiftUI
import AppKit
import SwiftTerm

@main
struct ShellDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("ShellDock", id: "main") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear { delegate.attach(state) }
        }
        .commands { AppCommands(state: state) }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.settings)
        }
    }
}

struct AppCommands: Commands {
    /// La barra de búsqueda es la integrada en SwiftTerm; se le envía la acción estándar de «Buscar».
    @MainActor static func find(_ action: NSFindPanelAction) {
        let item = NSMenuItem(); item.tag = Int(action.rawValue)
        NSApp.sendAction(#selector(TerminalView.performFindPanelAction(_:)), to: nil, from: item)
    }

    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nueva terminal local") { state.openLocal() }.keyboardShortcut("t", modifiers: .command)
            Button("Mini Linux interno") { state.openMiniLinux() }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Nueva sesión…") { state.editing = Session() }.keyboardShortcut("n", modifiers: .command)
            Button("Conexión rápida…") { NotificationCenter.default.post(name: .focusQuickConnect, object: nil) }.keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Cerrar pestaña") { if let id = state.selectedTabID { state.closeTab(id) } }.keyboardShortcut("w", modifiers: .command)
            Button("Reconectar pestaña") { state.selectedTab?.reconnect() }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Buscar en la terminal…") { Self.find(.showFindPanel) }.keyboardShortcut("f", modifiers: .command)
            Button("Resultado siguiente") { Self.find(.next) }.keyboardShortcut("g", modifiers: .command)
            Button("Resultado anterior") { Self.find(.previous) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandMenu("Pestañas") {
            Button("Pestaña siguiente") { state.selectNext(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Pestaña anterior") { state.selectNext(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button("Ir a la pestaña \(n)") { if state.tabs.indices.contains(n - 1) { state.select(state.tabs[n - 1].id) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
        CommandMenu("Herramientas") {
            Toggle("MultiExec (escribir en varias pestañas)", isOn: $state.multiExec).keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Snippets y macros") { state.showSnippets = true }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Túneles SSH") { state.showTunnels = true }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Herramientas de red") { state.showNetworkTools = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Claves SSH") { state.showKeys = true }.keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(state.sidebarVisible ? "Ocultar sesiones" : "Mostrar sesiones") { state.sidebarVisible.toggle() }.keyboardShortcut("b", modifiers: .command)
            Button(state.showFileBrowser ? "Ocultar panel de archivos" : "Mostrar panel de archivos") { state.showFileBrowser.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let focusQuickConnect = Notification.Name("ShellDock.focusQuickConnect")
}

/// Las opciones de desarrollo (--demo, --probe, --snapshot, --open, --vm-selftest) solo existen con SHELLDOCK_DEV=1 en el entorno.
enum DevMode { static let enabled = ProcessInfo.processInfo.environment["SHELLDOCK_DEV"] != nil }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var state: AppState?
    private var snapshotPath: String?
    private var demo = false
    private var probe: String?
    private var openFile: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let args = DevMode.enabled ? CommandLine.arguments : []
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) { snapshotPath = args[i + 1] }
        demo = args.contains("--demo")
        if let i = args.firstIndex(of: "--probe"), args.indices.contains(i + 1) { probe = args[i + 1] }
        if let i = args.firstIndex(of: "--open"), args.indices.contains(i + 1) { openFile = args[i + 1] }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        if DevMode.enabled && CommandLine.arguments.contains("--vm-selftest") { Task { @MainActor in await VMSelfTest.run() } }
    }

    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            if let state { urls.forEach(state.openExternal) } else { pendingURLs += urls }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func attach(_ s: AppState) {
        guard state == nil else { return }
        state = s
        defer { pendingURLs.forEach(s.openExternal); pendingURLs = [] }
        if demo { DemoData.populate(s) }
        else if let f = openFile, let d = try? Data(contentsOf: URL(fileURLWithPath: f)), var sess = try? TolerantJSON.decode(Session.self, from: d, defaults: Session()) {
            // solo para pruebas: guarda la contraseña de la sesión en el Llavero antes de abrirla
            if let pw = ProcessInfo.processInfo.environment["SHELLDOCK_DEV_PASSWORD"] { s.store.setPassword(pw, for: &sess) }
            s.open(session: sess)
        }
        else if s.tabs.isEmpty { s.openLocal() }
        if DevMode.enabled, let sheet = ProcessInfo.processInfo.environment["SHELLDOCK_DEMO_SHEET"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                switch sheet {
                case "editor": var n = Session(); n.name = "Servidor web"; n.host = "web1.example.com"; n.username = "deploy"; s.editing = n
                case "mini": var n = Session(); n.kind = .miniLinux; n.name = "Mini Linux"; s.editing = n
                case "network": s.showNetworkTools = true
                case "utilities": s.showUtilities = true
                case "servers": s.showServers = true
                case "tunnels": s.showTunnels = true
                case "keys": s.showKeys = true
                case "snippets": s.showSnippets = true
                default: break
                }
            }
        }
        if let cmd = probe {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["SHELLDOCK_PROBE_WAIT"] ?? "") ?? 6.0) - 4.0) { s.selectedTab?.sendText(cmd + "\r") }
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["SHELLDOCK_PROBE_WAIT"] ?? "") ?? 6.0)) {
                if let tv = s.selectedTab?.terminalView {
                    tv.selectAll(nil)
                    print("=== BUFFER ===")
                    print(tv.getSelection() ?? "(vacío)")
                    print("=== FIN ===")
                    if let m = FileBrowserModel.last {
                        print("=== SFTP === estado=\(m.state) ruta=\(m.path) entradas=\(m.entries.count) primeras=\(m.visibleEntries.prefix(6).map(\.name))")
                    }
                }
                NSApp.terminate(nil)
            }
        }
        if let path = snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["SHELLDOCK_SNAP_DELAY"] ?? "") ?? 3.0)) { Snapshot.take(to: path) }
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.tabs.forEach { $0.close() }
        return .terminateNow
    }
}

/// Captura de la ventana principal a PNG (herramienta de desarrollo: `--snapshot ruta.png`).
@MainActor
enum Snapshot {
    static func take(to path: String) {
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let view = win.contentView else { NSApp.terminate(nil); return }
        win.setContentSize(NSSize(width: 1280, height: 780))
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // captura real de la ventana (incluye vistas con capas Metal)
            let wid = CGWindowID(win.windowNumber)
            var image: CGImage?
            if win.attachedSheet != nil, let h = NSScreen.screens.first?.frame.height {
                // con un diálogo abierto se captura el rectángulo de la ventana con lo que hay encima (la hoja)
                let f = win.frame
                image = CGWindowListCreateImage(CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height), [.optionOnScreenAboveWindow, .optionIncludingWindow], wid, [.bestResolution])
            }
            if let cg = image ?? CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.boundsIgnoreFraming, .bestResolution]) {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            } else if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            }
            NSApp.terminate(nil)
        }
    }
}


/// Autoprueba de la VM: arranca Alpine, inicia sesión y ejecuta comandos (`--vm-selftest`).
@MainActor
enum VMSelfTest {
    static func run() async {
        func log(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
        log("VM soportada: \(MiniLinuxVM.supported)")
        let vm = MiniLinuxVM()
        if (try? MiniLinuxPersistence.prepare()) != nil { vm.persistFolder = MiniLinuxPersistence.folder }
        var buffer = ""
        vm.onOutput = { buffer += String(decoding: $0, as: UTF8.self) }
        vm.onStopped = { e in log("VM detenida \(e ?? "")") }
        do {
            let assets = try await MiniLinuxVM.prepareAssets { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
            log("imágenes listas: \(assets.kernel.lastPathComponent)")
            let t0 = Date()
            try await vm.start(assets: assets)
            log("VM arrancando…")
            func wait(_ needle: String, _ secs: Double) async -> Bool {
                let end = Date().addingTimeInterval(secs)
                while Date() < end { if buffer.contains(needle) { return true }; try? await Task.sleep(nanoseconds: 200_000_000) }
                return false
            }
            if await wait("login:", 120) {
                log("→ login detectado a los \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                buffer = ""
                vm.send(Array("root\r".utf8))
                if await wait("#", 20) {
                    buffer = ""
                    vm.send(Array((MiniLinuxPersistence.setupLine(cols: 100, rows: 30) + "\r").utf8))
                    _ = await wait("Alpine Linux 3", 120)
                    buffer = ""
                    let cmd = ProcessInfo.processInfo.environment["SHELLDOCK_VM_CMD"] ?? "uname -a; cat /etc/alpine-release"
                    vm.send(Array("\(cmd); echo FIN-$((6*7))\r".utf8))
                    _ = await wait("FIN-42", Double(ProcessInfo.processInfo.environment["SHELLDOCK_VM_WAIT"] ?? "") ?? 20)
                    log("=== SALIDA DEL LINUX ===\n" + buffer + "\n=== FIN ===")
                } else { log("sin prompt tras el login:\n" + buffer) }
            } else {
                log("no apareció 'login:'. Consola:\n" + buffer.suffix(3000))
            }
        } catch { log("ERROR: \(error.localizedDescription)") }
        vm.stop(force: true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
    }
}
