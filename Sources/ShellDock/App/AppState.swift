import AppKit
import SwiftUI
import Combine
import SwiftTerm

/// Estado global de la ventana: pestañas, selección, MultiExec, ajustes.
@MainActor
final class AppState: ObservableObject {
    let store: SessionStore
    let settings: AppSettings
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabID: UUID?
    @Published var multiExec = false
    @Published var tiled = false
    @Published var language = Loc.defaultCode
    @Published var recordingTabID: UUID?
    private var recorded: [UInt8] = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    @Published var sidebarVisible = true
    @Published var showFileBrowser = true
    @Published var editing: Session?
    @Published var showSettings = false
    @Published var showTunnels = false
    @Published var showSnippets = false
    @Published var showNetworkTools = false
    @Published var showKeys = false
    @Published var showUtilities = false
    @Published var showServers = false
    @Published var locked = MasterPassword.isSet
    let httpServer = HTTPFileServer()
    @Published var toast: String?
    let tunnels = TunnelManager()

    private var bag = Set<AnyCancellable>()

    init(store: SessionStore? = nil, settings: AppSettings? = nil) {
        // con --demo los datos de ejemplo van a un archivo temporal: nunca ensucian las sesiones reales
        let demoURL = FileManager.default.temporaryDirectory.appendingPathComponent("shelldock-demo-\(UUID().uuidString).json")
        let st = store ?? (DevMode.enabled && CommandLine.arguments.contains("--demo") ? SessionStore(url: demoURL) : SessionStore())
        let demoMode = DevMode.enabled && CommandLine.arguments.contains("--demo")
        let se = settings ?? (demoMode ? AppSettings(url: demoURL.deletingLastPathComponent().appendingPathComponent("shelldock-demo-settings-\(UUID().uuidString).json")) : AppSettings())
        self.store = st
        self.settings = se
        language = Loc.set(DevMode.enabled ? (ProcessInfo.processInfo.environment["SHELLDOCK_LANG"] ?? se.data.language) : se.data.language)
        if !demoMode { UserDefaults.standard.set([Loc.code], forKey: "AppleLanguages") }
        se.$data.map(\.language).removeDuplicates().dropFirst().sink { [weak self] code in
            self?.language = Loc.set(code)
            UserDefaults.standard.set([Loc.code], forKey: "AppleLanguages")      // menús y diálogos del sistema, tras reiniciar
        }.store(in: &bag)
        se.$data.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { for t in self.tabs { t.appearanceChanged(self.settings) } }
        }.store(in: &bag)
        st.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        se.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)      // p. ej. ancho de la barra lateral
    }

    var selectedTab: TerminalTab? { tabs.first { $0.id == selectedTabID } }

    // MARK: abrir pestañas

    @discardableResult
    func add(_ tab: TerminalTab) -> TerminalTab {
        installKeyMonitor()
        tab.app = self
        tabs.append(tab)
        selectedTabID = tab.id
        tab.start()
        DispatchQueue.main.async { tab.focus() }
        return tab
    }

    /// Abre una pestaña con el mini Linux interno (Alpine en una máquina virtual).
    func openMiniLinux() {
        var s = Session()
        s.kind = .miniLinux
        s.name = "Mini Linux"
        s.port = 0
        open(session: s)
    }

    func openLocal() {
        let n = tabs.filter { $0.kind == .local }.count + 1
        add(makeLocalTab(title: n == 1 ? tr("Terminal local") : tr("Terminal local %@", "\(n)")))
    }

    func makeLocalTab(title: String) -> ProcessTab {
        let shell = settings.data.defaultShell.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : settings.data.defaultShell
        let toolbox = settings.data.keepToolboxInPath
        return ProcessTab(title: title, kind: .local) {
            LaunchSpec(executable: shell, args: ["-l"], env: ProcessEnvironment.base(toolbox: toolbox), cwd: NSHomeDirectory(), display: shell)
        }
    }

    func open(session s: Session) {
        if let problem = s.validationError { toast = tr("No se abre la sesión: %@", "\(problem)"); return }
        switch s.kind {
        case .ssh:
            let data = settings.data
            let log: URL? = data.logSessions ? LogFiles.newLog(for: s.name) : nil
            let tab = ProcessTab(title: s.name, kind: .ssh, session: s) { SSHLauncher.spec(for: s, settings: data, logFile: log) }
            add(tab)
        case .local:
            add(makeLocalTab(title: s.name))
        case .telnet:
            add(StreamTab(title: s.name, kind: .telnet, session: s) { TelnetTransport(host: s.host, port: s.port) })
        case .tcp:
            add(StreamTab(title: s.name, kind: .tcp, session: s) { TCPTransport(host: s.host, port: s.port) })
        case .serial:
            add(StreamTab(title: s.name, kind: .serial, session: s) { SerialTransport(settings: s.serial) })
        case .miniLinux:
            add(StreamTab(title: s.name, kind: .miniLinux, session: s) { VMConsoleTransport(session: s) })
        case .vnc:
            add(VNCTab(session: s))
        case .sftp, .ftp:
            add(FileTab(session: s))
        case .rdp:
            toast = RDPLauncher.open(s)
        case .rlogin:
            add(StreamTab(title: s.name, kind: .rlogin, session: s) { RloginTransport(host: s.host, port: s.port, user: s.username) })
        case .browser:
            add(WebTab(session: s))
        case .mosh:
            guard let exe = MoshLauncher.executable() else { toast = tr("Mosh no está instalado: brew install mosh"); return }
            let toolbox = settings.data.keepToolboxInPath
            add(ProcessTab(title: s.name, kind: .mosh, session: s) {
                LaunchSpec(executable: exe, args: MoshLauncher.arguments(for: s), env: ProcessEnvironment.base(toolbox: toolbox), cwd: NSHomeDirectory(), display: "mosh \(s.host)")
            })
        default:
            toast = tr("%@: disponible en una fase posterior", "\(s.kind.title)")
        }
    }

    /// Conexión rápida: `usuario@host[:puerto]`, `ssh://…`, `telnet://…`.
    func quickConnect(_ text: String) {
        guard let s = parseQuick(text) else { return }
        open(session: s)
    }

    func parseQuick(_ text: String) -> Session? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var kind = SessionKind.ssh
        if let r = t.range(of: "://") {
            let scheme = String(t[t.startIndex..<r.lowerBound]).lowercased()
            if scheme == "http" || scheme == "https" {
                var w = Session(); w.kind = .browser; w.name = text; w.host = text
                return w
            }
            kind = SessionKind(rawValue: scheme) ?? .ssh
            t = String(t[r.upperBound...])
        }
        if let slash = t.firstIndex(of: "/") { t = String(t[t.startIndex..<slash]) }      // ssh://host/ruta → host
        var s = Session()
        s.kind = kind
        s.port = kind.defaultPort
        if let at = t.lastIndex(of: "@") {
            s.username = String(t[t.startIndex..<at])
            t = String(t[t.index(after: at)...])
        }
        if let colon = t.lastIndex(of: ":"), let p = Int(t[t.index(after: colon)...]) {
            s.port = p
            t = String(t[t.startIndex..<colon])
        }
        s.host = t
        s.name = s.username.isEmpty ? s.host : "\(s.username)@\(s.host)"
        return s
    }

    /// Enlaces ssh:// y telnet:// de otras aplicaciones o páginas web: siempre se pide confirmación antes de conectar.
    func openExternal(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "ssh" || scheme == "telnet", var s = parseQuick(url.absoluteString) else { return }
        s = s.sanitizedForImport()
        if let problem = s.validationError { toast = "Enlace rechazado: \(problem)"; return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = tr("¿Abrir una conexión %@?", "\(s.kind.title)")
        alert.informativeText = tr("Una página web o aplicación pide conectar a %@%@:%@. Conecta solo si reconoces el servidor.", "\(s.username.isEmpty ? "" : s.username + "@")", "\(s.host)", "\(s.port)")
        alert.addButton(withTitle: tr("Conectar")); alert.addButton(withTitle: tr("Cancelar"))
        if alert.runModal() == .alertFirstButtonReturn { open(session: s) }
    }

    // MARK: cerrar / navegar

    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let t = tabs[i]
        t.close()
        tabs.remove(at: i)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
            DispatchQueue.main.async { self.selectedTab?.focus() }
        }
    }

    func select(_ id: UUID) {
        selectedTabID = id
        DispatchQueue.main.async { self.selectedTab?.focus() }
    }

    func selectNext(_ delta: Int) {
        guard !tabs.isEmpty, let cur = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        select(tabs[(cur + delta + tabs.count) % tabs.count].id)
    }

    // MARK: MultiExec y snippets

    /// SwiftTerm conecta el teclado de la terminal local directamente al proceso, sin pasar por el delegado.
    /// Por eso se observan las teclas a nivel de aplicación: sirve a la grabación de macros y al espejo de MultiExec.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.observe(e) }
            return e
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] e in
            MainActor.assumeIsolated { (self?.rightClickPaste(e) ?? false) ? nil : e }
        }
    }

    /// Clic derecho sobre una terminal: pega el portapapeles (y lo replica en MultiExec). Se puede desactivar en Ajustes.
    private func rightClickPaste(_ e: NSEvent) -> Bool {
        if e.type == .leftMouseDown, !e.modifierFlags.contains(.control) { return false }     // Ctrl+clic = clic derecho en macOS
        guard settings.data.rightClickPaste, let frame = e.window?.contentView?.superview,
              var v = frame.hitTest(frame.convert(e.locationInWindow, from: nil)) else { return false }
        while !(v is TerminalView), let s = v.superview { v = s }
        guard let tv = v as? TerminalView, let tab = tabs.first(where: { $0.terminalView === tv }),
              let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        e.window?.makeFirstResponder(tv)
        tv.paste(tv)
        tab.onUserInput?(Array(text.utf8)[...])
        if multiExec, !tab.excluded { for t in multiTargets where t !== tab { t.sendText(text) } }
        return true
    }

    private func observe(_ e: NSEvent) {
        guard let tv = NSApp.keyWindow?.firstResponder as? TerminalView,
              let tab = tabs.first(where: { $0.terminalView === tv }) else { return }
        var text: String?
        if e.modifierFlags.contains(.command) {
            if e.charactersIgnoringModifiers == "v" { text = NSPasteboard.general.string(forType: .string) }
        } else {
            text = KeyCatcher.sequence(for: e)
        }
        guard let text, !text.isEmpty else { return }
        tab.onUserInput?(Array(text.utf8)[...])
        guard multiExec, !tab.excluded else { return }
        for t in multiTargets where t !== tab { t.sendText(text) }     // la propia terminal ya recibe la tecla de forma nativa
    }

    // MARK: grabación de macros

    func startRecording() {
        guard let tab = selectedTab, tab.acceptsInput else { flash(tr("Selecciona una terminal para grabar")); return }
        recorded = []
        recordingTabID = tab.id
        tab.onUserInput = { [weak self] d in self?.recorded.append(contentsOf: d) }
        flash(tr("Grabando macro… vuelve a pulsar Macros → Detener"))
    }

    func stopRecording() {
        guard let id = recordingTabID else { return }
        tabs.first { $0.id == id }?.onUserInput = nil
        recordingTabID = nil
        let text = MacroRecorder.text(from: recorded)
        guard !text.isEmpty else { flash(tr("Macro vacía: no se guardó")); return }
        var sn = Snippet(); sn.name = tr("Macro %@", "\(Date().formatted(date: .omitted, time: .standard))"); sn.text = text
        store.snippets.append(sn)
        flash("Macro guardada: \(sn.name)")
    }

    /// Pestañas que reciben lo que se escribe en MultiExec: todas las de terminal salvo las excluidas.
    var multiTargets: [TerminalTab] { tabs.filter { $0.acceptsInput && !$0.excluded } }

    /// Envía texto a la pestaña activa o, con MultiExec, a todas las no excluidas.
    func send(_ text: String, toAll: Bool = false) {
        if toAll || multiExec {
            for t in multiTargets { t.sendText(text) }
        } else {
            selectedTab?.sendText(text)
        }
    }

    /// Ejecuta un snippet (con variables y pausas) en la pestaña activa o en todas las de MultiExec.
    func run(snippet: Snippet, toAll: Bool = false) {
        let targets: [TerminalTab] = (toAll || multiExec) ? multiTargets : (selectedTab.map { [$0] } ?? [])
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        Task { @MainActor in
            for tab in targets {
                let text = SnippetRunner.expand(snippet.text, session: tab.session, clipboard: clip)
                let steps = SnippetRunner.steps(text, sendReturn: snippet.sendReturn)
                Task { @MainActor in
                    for step in steps {
                        switch step {
                        case .text(let t): tab.sendText(t); try? await Task.sleep(nanoseconds: 60_000_000)
                        case .wait(let s): try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                        }
                    }
                }
            }
        }
    }

    func run(snippet: Snippet) { run(snippet: snippet, toAll: false) }

    func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.toast == message { self?.toast = nil } }
    }
}

enum LogFiles {
    static func newLog(for name: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        let url = Paths.logsDir.appendingPathComponent("\(safe)-\(f.string(from: Date())).log")
        // el log puede contener datos sensibles: se crea solo legible por el propietario
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        return url
    }
}
