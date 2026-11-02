import AppKit
import SwiftUI
import SwiftTerm

enum TabStatus: Equatable {
    case connecting, connected, closed
    case failed(String)

    var label: String {
        switch self {
        case .connecting: return "Conectando…"
        case .connected: return "Conectado"
        case .closed: return "Cerrada"
        case .failed(let m): return m
        }
    }
}

/// Base de todas las pestañas (terminal local, SSH, Telnet, serie, VNC, mini Linux…).
@MainActor
class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var status: TabStatus = .connecting
    @Published var tintHex: String?
    /// MultiExec: la pestaña no recibe lo que se escribe en todas.
    @Published var excluded = false
    var acceptsInput: Bool { terminalView != nil }
    let kind: SessionKind
    var session: Session?
    weak var app: AppState?
    var onClosed: ((TerminalTab) -> Void)?

    init(title: String, kind: SessionKind, session: Session? = nil) {
        self.title = title
        self.kind = kind
        self.session = session
        self.tintHex = session?.colorHex
    }

    /// Vista que se muestra en el área de contenido.
    var content: NSView { fatalError("implementar en la subclase") }
    var terminalView: TerminalView? { nil }
    var canReconnect: Bool { false }
    /// Sesión SSH con la que el panel SFTP puede compartir la conexión.
    var fileBrowserSession: Session? { nil }

    func start() {}
    func close() {}
    func reconnect() {}
    func focus() { content.window?.makeFirstResponder(terminalView ?? content) }

    /// Envía texto como si se hubiera tecleado.
    func sendText(_ s: String) {}

    func appearanceChanged(_ settings: AppSettings) {
        guard let tv = terminalView else { return }
        TabAppearance.apply(to: tv, settings: settings.data, session: session)
    }
}

enum TabAppearance {
    @MainActor
    static func apply(to tv: TerminalView, settings: AppSettingsData, session: Session?) {
        let size = CGFloat((session?.fontSize ?? 0) > 0 ? session!.fontSize : settings.fontSize)
        let font = NSFont(name: settings.fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let name = (session?.themeName.isEmpty == false) ? session!.themeName : settings.themeName
        TerminalTheme.named(name).apply(to: tv, font: font)
        tv.optionAsMetaKey = settings.optionAsMeta
        tv.changeScrollback(settings.scrollback)
    }
}

/// Pestaña con un proceso en un pty: terminal local, SSH, mini Linux por consola...
@MainActor
final class ProcessTab: TerminalTab, LocalProcessTerminalViewDelegate {
    let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    private let makeSpec: () -> LaunchSpec
    private var reconnectTask: Task<Void, Never>?
    private var closedByUser = false
    private(set) var lastSpec: LaunchSpec?
    private(set) var startedAt = Date()

    init(title: String, kind: SessionKind, session: Session? = nil, spec: @escaping () -> LaunchSpec) {
        self.makeSpec = spec
        super.init(title: title, kind: kind, session: session)
        tv.processDelegate = self
    }

    override var content: NSView { tv }
    override var terminalView: TerminalView? { tv }
    override var canReconnect: Bool { true }
    override var fileBrowserSession: Session? { kind == .ssh ? session : nil }

    override func start() {
        if let a = app { appearanceChanged(a.settings) }
        let spec = makeSpec()
        lastSpec = spec
        startedAt = Date()
        status = .connecting
        tv.startProcess(executable: spec.executable, args: spec.args, environment: spec.env, execName: nil, currentDirectory: spec.cwd)
        // se considera conectado en cuanto el proceso arranca; el estado se afina al recibir salida
        status = .connected
    }

    override func close() {
        closedByUser = true
        reconnectTask?.cancel()
        tv.terminate()
        status = .closed
    }

    override func reconnect() {
        reconnectTask?.cancel()
        closedByUser = false
        tv.feed(text: "\r\n\u{1b}[33m— Reconectando… —\u{1b}[0m\r\n")
        start()
    }

    override func sendText(_ s: String) {
        tv.send(txt: s)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        if kind == .local || session == nil { self.title = title.isEmpty ? self.title : title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !closedByUser else { return }
        let code = exitCode.map(String.init) ?? "señal"
        status = (exitCode == 0 || exitCode == nil) ? .closed : .failed("Terminó con código \(code)")
        tv.feed(text: "\r\n\u{1b}[2m[Proceso terminado (\(code))]\u{1b}[0m\r\n")
        if let s = session, s.autoReconnect, exitCode != 0 {
            tv.feed(text: "\u{1b}[2m[Reconectando en 3 s…]\u{1b}[0m\r\n")
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.reconnect()
            }
        } else if kind == .local, let app {
            app.closeTab(id)           // al hacer `exit` en el shell local se cierra la pestaña
        }
    }
}
