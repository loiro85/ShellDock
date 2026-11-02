import AppKit
import SwiftTerm

/// Pestaña de terminal conectada a un `ByteTransport` (Telnet, TCP crudo, serie).
@MainActor
final class StreamTab: TerminalTab, TerminalViewDelegate {
    let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    private var transport: ByteTransport
    private let makeTransport: () -> ByteTransport
    private var closedByUser = false

    init(title: String, kind: SessionKind, session: Session? = nil, transport: @escaping () -> ByteTransport) {
        makeTransport = transport
        self.transport = transport()
        super.init(title: title, kind: kind, session: session)
        tv.terminalDelegate = self
    }

    override var content: NSView { tv }
    override var terminalView: TerminalView? { tv }
    override var canReconnect: Bool { true }

    override func start() {
        if let a = app { appearanceChanged(a.settings) }
        closedByUser = false
        status = .connecting
        wire()
        transport.open()
    }

    private func wire() {
        transport.onOpen = { [weak self] in self?.status = .connected }
        transport.onData = { [weak self] bytes in
            guard let self else { return }
            let hl = self.app?.settings.data.highlightKeywords ?? false
            self.tv.feed(byteArray: (hl ? KeywordHighlighter.process(bytes) : bytes)[...])
        }
        transport.onClose = { [weak self] err in
            guard let self, !self.closedByUser else { return }
            self.status = err == nil ? .closed : .failed(err!)
            self.tv.feed(text: "\r\n\u{1b}[2m[Conexión cerrada\(err.map { ": \($0)" } ?? "")]\u{1b}[0m\r\n")
        }
    }

    override func close() {
        closedByUser = true
        transport.close()
        status = .closed
    }

    override func reconnect() {
        transport.close()
        transport = makeTransport()
        tv.feed(text: "\r\n\u{1b}[33m— Reconectando… —\u{1b}[0m\r\n")
        start()
    }

    override func sendText(_ s: String) { transport.send(Array(s.utf8)) }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) { onUserInput?(data); transport.send(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { transport.resize(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let u = URL(string: link) { NSWorkspace.shared.open(u) }
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(content, forType: .string)
    }
    func clipboardRead(source: TerminalView) -> Data? { NSPasteboard.general.data(forType: .string) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
