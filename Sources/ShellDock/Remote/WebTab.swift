import AppKit
import WebKit

/// Sesión «Navegador»: abre una página web (paneles de administración, wikis internas…) dentro de una pestaña.
@MainActor
final class WebTab: TerminalTab {
    private let delegate = WebDelegate()
    private let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    private let address: String

    init(session: Session) {
        var a = session.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.contains("://") { a = "https://" + a }
        address = a
        super.init(title: session.name, kind: .browser, session: session)
        delegate.tab = self
        web.navigationDelegate = delegate
    }

    override var content: NSView { web }
    override var canReconnect: Bool { true }
    override func focus() { content.window?.makeFirstResponder(web) }

    override func start() {
        status = .connecting
        guard let url = URL(string: address) else { status = .failed("Dirección no válida"); return }
        web.load(URLRequest(url: url))
    }

    override func reconnect() { web.reload() }
    override func close() { web.stopLoading(); status = .closed }

    fileprivate func loaded(_ w: WKWebView) {
        status = .connected
        if let t = w.title, !t.isEmpty, session?.name.isEmpty != false { title = t }
    }
    fileprivate func failed(_ e: Error) { status = .failed(e.localizedDescription) }
}

/// WKWebView exige un delegado NSObject; `TerminalTab` no lo es, así que este objeto reenvía los eventos.
private final class WebDelegate: NSObject, WKNavigationDelegate {
    weak var tab: WebTab?
    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) { Task { @MainActor in tab?.loaded(w) } }
    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { Task { @MainActor in tab?.failed(error) } }
    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { Task { @MainActor in tab?.failed(error) } }
}
