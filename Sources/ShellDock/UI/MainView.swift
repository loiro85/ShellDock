import SwiftUI
import AppKit

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

    final class Container: NSView {
        var hosted: NSView?
        func host(_ v: NSView) {
            if hosted === v { return }
            hosted?.removeFromSuperview()
            hosted = v
            v.removeFromSuperview()
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
    }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        c.host(view)
        return c
    }

    func updateNSView(_ c: Container, context: Context) {
        c.host(view)
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
