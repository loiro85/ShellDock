import AppKit
import SwiftUI
import Combine

/// Estado global de la ventana: pestañas, selección, MultiExec, ajustes.
@MainActor
final class AppState: ObservableObject {
    let store: SessionStore
    let settings: AppSettings
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabID: UUID?
    @Published var multiExec = false
    @Published var tiled = false
    @Published var sidebarVisible = true
    @Published var showFileBrowser = true
    @Published var editing: Session?
    @Published var showSettings = false
    @Published var showTunnels = false
    @Published var showSnippets = false
    @Published var showNetworkTools = false
    @Published var showKeys = false
    @Published var toast: String?
    let tunnels = TunnelManager()

    private var bag = Set<AnyCancellable>()

    init(store: SessionStore? = nil, settings: AppSettings? = nil) {
        let st = store ?? SessionStore()
        let se = settings ?? AppSettings()
        self.store = st
        self.settings = se
        se.$data.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { for t in self.tabs { t.appearanceChanged(self.settings) } }
        }.store(in: &bag)
        st.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    var selectedTab: TerminalTab? { tabs.first { $0.id == selectedTabID } }

    // MARK: abrir pestañas

    @discardableResult
    func add(_ tab: TerminalTab) -> TerminalTab {
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
        add(makeLocalTab(title: n == 1 ? "Terminal local" : "Terminal local \(n)"))
    }

    func makeLocalTab(title: String) -> ProcessTab {
        let shell = settings.data.defaultShell.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : settings.data.defaultShell
        let toolbox = settings.data.keepToolboxInPath
        return ProcessTab(title: title, kind: .local) {
            LaunchSpec(executable: shell, args: ["-l"], env: ProcessEnvironment.base(toolbox: toolbox), cwd: NSHomeDirectory(), display: shell)
        }
    }

    func open(session s: Session) {
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
        default:
            toast = "\(s.kind.title): disponible en una fase posterior"
        }
    }

    /// Conexión rápida: `usuario@host[:puerto]`, `ssh://…`, `telnet://…`.
    func quickConnect(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var kind = SessionKind.ssh
        if let r = t.range(of: "://") {
            let scheme = String(t[t.startIndex..<r.lowerBound]).lowercased()
            kind = SessionKind(rawValue: scheme) ?? .ssh
            t = String(t[r.upperBound...])
        }
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
        open(session: s)
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
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return Paths.logsDir.appendingPathComponent("\(safe)-\(f.string(from: Date())).log")
    }
}
