import AppKit
import SwiftUI

/// Pestaña solo de archivos (sesiones SFTP / FTP / FTPS): el explorador ocupa toda el área.
@MainActor
final class FileTab: TerminalTab {
    private lazy var host: NSView = {
        let root = FileBrowserPanel(session: session!, tab: self, direct: true).environmentObject(app!)
        return NSHostingView(rootView: root)
    }()

    init(session: Session) {
        super.init(title: session.name, kind: session.kind, session: session)
        status = .connected
    }

    override var content: NSView { host }
    override func focus() {}
}
