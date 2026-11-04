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
                    .frame(width: CGFloat(min(max(state.settings.data.sidebarWidth, SidebarResizer.minWidth), SidebarResizer.maxWidth)))
                SidebarResizer()
            }
            VStack(spacing: 0) {
                Ribbon(quick: $quick, quickFocused: $quickFocused)
                Divider()
                TabBarView()
                Divider()
                ContentArea()
                if state.multiExec { MultiExecInput() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusQuickConnect)) { _ in quickFocused = true }
        .sheet(item: $state.editing) { s in SessionEditor(session: s) }
        .sheet(isPresented: $state.showSnippets) { SnippetsView().environmentObject(state) }
        .sheet(isPresented: $state.showTunnels) { TunnelsView().environmentObject(state) }
        .sheet(isPresented: $state.showNetworkTools) { NetworkToolsView().environmentObject(state) }
        .sheet(isPresented: $state.showKeys) { KeysView().environmentObject(state) }
        .sheet(isPresented: $state.showUtilities) { UtilitiesView() }
        .sheet(isPresented: $state.showServers) { ServersView().environmentObject(state) }
        .overlay { if state.locked { LockView() } }
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

/// Borde arrastrable de la barra lateral: cambia el ancho (se guarda en Ajustes); doble clic restablece; arrastrar hasta el límite la oculta.
struct SidebarResizer: View {
    static let minWidth: Int = 180, maxWidth: Int = 640, defaultWidth: Int = 290
    @EnvironmentObject var state: AppState
    @State private var startWidth: Int?

    var body: some View {
        Color.clear.frame(width: 7).contentShape(Rectangle())
            .overlay { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let start = startWidth ?? state.settings.data.sidebarWidth
                    startWidth = start
                    state.settings.data.sidebarWidth = min(max(start + Int(g.translation.width), Self.minWidth), Self.maxWidth)
                }
                .onEnded { g in
                    if let start = startWidth, start + Int(g.translation.width) < Self.minWidth - 60 { state.sidebarVisible = false }
                    startWidth = nil
                })
            .onTapGesture(count: 2) { state.settings.data.sidebarWidth = Self.defaultWidth }
    }
}

/// Contenedor que muestra la vista nativa de la pestaña activa (la misma instancia, sin recrearla).
struct ContentArea: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            if state.multiExec || state.tiled {
                TileGridView()
            } else if let tab = state.selectedTab {
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
        VStack(spacing: 0) {
            panels
            if state.settings.data.remoteMonitor, tab.kind == .ssh, let s = tab.session {
                Divider()
                MonitorBar(session: s, hostKeyPolicy: state.settings.data.hostKeyPolicy).id(tab.id)
            }
        }
    }

    var panels: some View {
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
