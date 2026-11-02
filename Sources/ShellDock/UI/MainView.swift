import SwiftUI
import AppKit
import SwiftTerm

struct MainView: View {
    @EnvironmentObject var state: AppState
    @State private var quick = ""
    @FocusState private var quickFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if state.sidebarVisible {
                SidebarView()
                    .frame(width: 290)
                Divider()
            }
            VStack(spacing: 0) {
                TabBarView()
                Divider()
                ContentArea()
                if state.multiExec { MultiExecBar() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { state.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }.help("Mostrar/ocultar sesiones (⌘B)")
            }
            ToolbarItemGroup(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal").foregroundStyle(.secondary)
                    TextField("Conexión rápida: usuario@host[:puerto]  (⌘K)", text: $quick)
                        .textFieldStyle(.plain)
                        .frame(width: 360)
                        .focused($quickFocused)
                        .onSubmit {
                            state.quickConnect(quick)
                            quick = ""
                        }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.openLocal() } label: { Image(systemName: "apple.terminal") }.help("Nueva terminal local (⌘T)")
                Button { state.openMiniLinux() } label: { Image(systemName: "shippingbox") }.help("Mini Linux interno (⌥⌘L)")
                Button { state.editing = Session() } label: { Image(systemName: "plus.circle") }.help("Nueva sesión (⌘N)")
                Toggle(isOn: $state.multiExec) { Image(systemName: "dot.radiowaves.left.and.right") }
                    .toggleStyle(.button).help("MultiExec: escribir en todas las pestañas marcadas")
                Menu {
                    Button("Snippets y macros") { state.showSnippets = true }
                    Button("Túneles SSH") { state.showTunnels = true }
                    Button("Herramientas de red") { state.showNetworkTools = true }
                    Button("Claves SSH") { state.showKeys = true }
                    Divider()
                    Button("Ajustes…") { SettingsOpener.open() }
                } label: { Image(systemName: "wrench.and.screwdriver") }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusQuickConnect)) { _ in quickFocused = true }
        .sheet(item: $state.editing) { s in SessionEditor(session: s) }
        .sheet(isPresented: $state.showSnippets) { SnippetsView().environmentObject(state) }
        .sheet(isPresented: $state.showTunnels) { TunnelsView().environmentObject(state) }
        .sheet(isPresented: $state.showNetworkTools) { NetworkToolsView().environmentObject(state) }
        .sheet(isPresented: $state.showKeys) { KeysView().environmentObject(state) }
        .overlay(alignment: .bottom) {
            if let t = state.toast {
                Text(t).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.toast)
    }
}

/// Contenedor que muestra la vista nativa de la pestaña activa (la misma instancia, sin recrearla).
struct ContentArea: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            if let tab = state.selectedTab {
                TabContentView(tab: tab)
            } else {
                WelcomeView()
            }
        }
    }
}

struct TabContentView: View {
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            if state.showFileBrowser, let s = tab.fileBrowserSession {
                FileBrowserPanel(session: s, tab: tab)
                    .id(tab.id)
                    .frame(width: CGFloat(state.settings.data.sftpPanelWidth))
                Divider()
            }
            NSViewHost(view: tab.content, tabID: tab.id)
        }
    }
}

struct NSViewHost: NSViewRepresentable {
    let view: NSView
    let tabID: UUID
    var inset: NSEdgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 4)

    final class Container: NSView {
        var hosted: NSView?
        var inset = NSEdgeInsets()

        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
        required init?(coder: NSCoder) { fatalError() }

        func host(_ v: NSView, inset: NSEdgeInsets) {
            self.inset = inset
            if hosted === v { syncBackground(); return }
            hosted?.removeFromSuperview()
            hosted = v
            v.removeFromSuperview()
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.left),
                v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.right),
                v.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
                v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom),
            ])
            syncBackground()
        }

        /// El margen toma el mismo color que el terminal para que no se note.
        func syncBackground() {
            layer?.backgroundColor = (hosted as? TerminalView)?.nativeBackgroundColor.cgColor ?? NSColor.windowBackgroundColor.cgColor
        }
    }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        c.host(view, inset: view is TerminalView ? inset : NSEdgeInsets())
        return c
    }

    func updateNSView(_ c: Container, context: Context) {
        c.host(view, inset: view is TerminalView ? inset : NSEdgeInsets())
        DispatchQueue.main.async { c.window?.makeFirstResponder(view) }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("ShellDock").font(.largeTitle.bold())
            Text("Terminales, SSH, SFTP, túneles y mucho más, sin límites.").foregroundStyle(.secondary)
            HStack {
                Button("Terminal local") { state.openLocal() }.keyboardShortcut(.defaultAction)
                Button("Nueva sesión…") { state.editing = Session() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


enum SettingsOpener {
    @MainActor
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}


/// MultiExec: una barra de comandos que escribe en todas las pestañas marcadas a la vez.
struct MultiExecBar: View {
    @EnvironmentObject var state: AppState
    @State private var text = ""

    var targets: [TerminalTab] { state.tabs.filter { $0.broadcast } }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.orange)
                Text("MultiExec").font(.caption.bold())
                TextField("Escribe un comando y pulsa Intro: se envía a \(targets.count) pestañas", text: $text)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .onSubmit { send() }
                Button("Enviar") { send() }.disabled(targets.isEmpty || text.isEmpty)
                Menu("Pestañas") {
                    Button("Marcar todas") { for t in state.tabs { t.broadcast = true } }
                    Button("Desmarcar todas") { for t in state.tabs { t.broadcast = false } }
                    Divider()
                    ForEach(state.tabs) { t in
                        Button((t.broadcast ? "✓ " : "   ") + t.title) { t.broadcast.toggle() }
                    }
                }.frame(width: 90)
            }.padding(8).background(.bar)
        }
    }

    func send() {
        guard !text.isEmpty else { return }
        for t in targets { t.sendText(text + "\r") }
        text = ""
    }
}
