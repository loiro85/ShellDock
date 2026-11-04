import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var state: AppState
    @State private var dragging: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(state.tabs) { tab in
                    TabButton(tab: tab)
                        .opacity(dragging == tab.id ? 0.45 : 1)
                        .onDrag { dragging = tab.id; return NSItemProvider(object: tab.id.uuidString as NSString) }
                        .onDrop(of: [.plainText], delegate: TabDropDelegate(target: tab.id, dragging: $dragging, state: state))
                }
                Menu {
                    Button("Terminal local") { state.openLocal() }
                    Button("Mini Linux") { state.openMiniLinux() }
                    Button("Nueva sesión…") { state.editing = Session() }
                    if !state.store.sessions.isEmpty {
                        Divider()
                        ForEach(state.store.sessions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.prefix(25)) { s in
                            Button(s.name) { state.open(session: s) }
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                } primaryAction: { state.openLocal() }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Nueva terminal local (⌘T). Mantén pulsado para elegir otra sesión")
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 34)
        .background(.bar)
    }
}

/// Reordena las pestañas al arrastrarlas: la pestaña arrastrada ocupa el sitio de la que tiene debajo.
struct TabDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let state: AppState

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target,
              let a = state.tabs.firstIndex(where: { $0.id == from }), let b = state.tabs.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { state.tabs.move(fromOffsets: IndexSet(integer: a), toOffset: b > a ? b + 1 : b) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropExited(info: DropInfo) {}
}

struct TabButton: View {
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject var state: AppState
    @State private var hover = false

    func rename() {
        let alert = NSAlert()
        alert.messageText = tr("Renombrar pestaña")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = tab.title
        alert.accessoryView = field
        alert.addButton(withTitle: tr("Renombrar")); alert.addButton(withTitle: tr("Cancelar"))
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { tab.title = SessionSafety.stripControl(field.stringValue) }
    }

    var selected: Bool { state.selectedTabID == tab.id }

    var statusColor: Color {
        switch tab.status {
        case .connected: return .green
        case .connecting: return .orange
        case .closed: return .gray
        case .failed: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.kind.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(tab.title).lineLimit(1).font(.system(size: 12, weight: selected ? .semibold : .regular)).frame(maxWidth: 170, alignment: .leading)
            if state.multiExec && tab.acceptsInput && !tab.excluded {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10)).foregroundStyle(.orange)
            }
            Button { state.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 16).background(Circle().fill(Color.primary.opacity(hover ? 0.12 : 0)))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.14) : (hover ? Color.primary.opacity(0.06) : .clear)))
        .overlay(alignment: .bottom) {
            if let hex = tab.tintHex { Rectangle().fill(Color(nsColor: NSColor(hex: hex))).frame(height: 2).padding(.horizontal, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.select(tab.id) }
        .onHover { hover = $0 }
        .help(tab.status.label)
        .contextMenu {
            if tab.canReconnect { Button("Reconectar") { tab.reconnect() } }
            Button("Renombrar pestaña…") { rename() }
            if tab.acceptsInput { Button(tab.excluded ? tr("Incluir en MultiExec") : tr("Excluir de MultiExec")) { tab.excluded.toggle() } }
            Menu("Color de pestaña") {
                Button("Ninguno") { tab.tintHex = nil }
                ForEach(Palette.colors, id: \.self) { hex in Button(Palette.name(hex)) { tab.tintHex = hex } }
            }
            Button("Duplicar pestaña") { if let s = tab.session { state.open(session: s) } else { state.openLocal() } }
            Divider()
            Button("Cerrar otras") { for t in state.tabs where t.id != tab.id { state.closeTab(t.id) } }
            Button("Cerrar todas") { for t in state.tabs { state.closeTab(t.id) } }
            Button("Cerrar") { state.closeTab(tab.id) }
        }
    }
}

enum Palette {
    static let colors = ["#ff6b6b", "#ff9f43", "#ffd166", "#7ee787", "#56d4dd", "#6cb6ff", "#d2a8ff", "#ff79c6"]
    static func name(_ hex: String) -> String {
        ["#ff6b6b": tr("Rojo"), "#ff9f43": tr("Naranja"), "#ffd166": tr("Amarillo"), "#7ee787": tr("Verde"), "#56d4dd": tr("Turquesa"), "#6cb6ff": tr("Azul"), "#d2a8ff": tr("Violeta"), "#ff79c6": tr("Rosa")][hex] ?? hex
    }
}
