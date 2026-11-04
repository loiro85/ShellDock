import Foundation
import Combine

struct AppSettingsData: Codable {
    var fontName = "Menlo"
    var fontSize = 13
    var themeName = "ShellDock Oscuro"
    var scrollback = 20000
    var copyOnSelect = false
    var optionAsMeta = true
    var cursorStyle = "block"
    var confirmClose = true
    var hostKeyPolicy = "accept-new"    // accept-new, ask, no
    var defaultShell = ""
    var logSessions = false
    var terminalBell = true
    var keepToolboxInPath = true
    var sftpPanelWidth = 320
    var sidebarVisible = true
    var highlightKeywords = true
    var internalEditor = true
    var remoteMonitor = true
    var language = Loc.defaultCode      // inglés por defecto

    init() {}

    /// Decodificación tolerante: los ajustes guardados por versiones anteriores no traen los campos nuevos.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decodeIfPresent(T.self, forKey: k) { v = x } }
        get(.fontName, &fontName); get(.fontSize, &fontSize); get(.themeName, &themeName); get(.scrollback, &scrollback)
        get(.copyOnSelect, &copyOnSelect); get(.optionAsMeta, &optionAsMeta); get(.cursorStyle, &cursorStyle)
        get(.confirmClose, &confirmClose); get(.hostKeyPolicy, &hostKeyPolicy); get(.defaultShell, &defaultShell)
        get(.logSessions, &logSessions); get(.terminalBell, &terminalBell); get(.keepToolboxInPath, &keepToolboxInPath)
        get(.sftpPanelWidth, &sftpPanelWidth); get(.sidebarVisible, &sidebarVisible)
        get(.highlightKeywords, &highlightKeywords); get(.internalEditor, &internalEditor); get(.remoteMonitor, &remoteMonitor); get(.language, &language)
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var data = AppSettingsData()
    private var cancellable: AnyCancellable?
    private let url: URL

    init(url: URL = Paths.settingsFile) {
        self.url = url
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppSettingsData.self, from: d) { data = s }
        cancellable = $data.dropFirst().debounce(for: .milliseconds(300), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.save() }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(data) { try? d.write(to: url, options: .atomic) }
    }

    var theme: TerminalTheme { TerminalTheme.named(data.themeName) }
}
