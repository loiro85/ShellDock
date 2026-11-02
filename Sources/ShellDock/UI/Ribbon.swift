import SwiftUI
import AppKit

/// Barra de botones con icono y texto, al estilo de la cinta de MobaXterm.
struct Ribbon: View {
    @EnvironmentObject var state: AppState
    @Binding var quick: String
    var quickFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 2) {
            RibbonButton(icon: "person.crop.rectangle.badge.plus", label: "Sesión", help: "Nueva sesión (⌘N)") { state.editing = Session() }
            RibbonButton(icon: "apple.terminal", label: "Terminal", help: "Nueva terminal local (⌘T)") { state.openLocal() }
            RibbonButton(icon: "shippingbox", label: "Mini Linux", help: "Linux interno en una máquina virtual (⌥⌘L)") { state.openMiniLinux() }
            RibbonButton(icon: "folder.badge.gearshape", label: "SFTP", help: "Nueva sesión SFTP") {
                var s = Session(); s.kind = .sftp; s.port = 22; state.editing = s
            }
            Divider().frame(height: 36).padding(.horizontal, 4)
            RibbonMenu(icon: "wrench.and.screwdriver", label: "Herramientas") {
                Button("Herramientas de red") { state.showNetworkTools = true }
                Button("Claves SSH") { state.showKeys = true }
            }
            RibbonButton(icon: "text.badge.checkmark", label: "Macros", help: "Snippets y macros") { state.showSnippets = true }
            RibbonButton(icon: "arrow.left.arrow.right.square", label: "Túneles", help: "Túneles SSH") { state.showTunnels = true }
            Divider().frame(height: 36).padding(.horizontal, 4)
            RibbonButton(icon: "sidebar.left", label: "Sesiones", help: "Mostrar/ocultar la lista de sesiones (⌘B)", active: state.sidebarVisible) { state.sidebarVisible.toggle() }
            RibbonButton(icon: "square.grid.2x2", label: "Dividir", help: "Ver todas las terminales a la vez", active: state.tiled) { state.tiled.toggle() }
            RibbonButton(icon: "dot.radiowaves.left.and.right", label: "MultiExec", help: "Escribir en todas las terminales a la vez", active: state.multiExec) { state.multiExec.toggle() }
            RibbonButton(icon: "gearshape", label: "Ajustes", help: "Preferencias") { SettingsOpener.open() }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal").foregroundStyle(.secondary)
                TextField("Conexión rápida: usuario@host  (⌘K)", text: $quick)
                    .textFieldStyle(.plain).frame(minWidth: 160, maxWidth: 260)
                    .focused(quickFocused)
                    .onSubmit { state.quickConnect(quick); quick = "" }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
    }
}

struct RibbonButton: View {
    let icon: String, label: String, help: String
    var active = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20, weight: .regular)).frame(height: 24)
                Text(label).font(.system(size: 10.5)).lineLimit(1)
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .frame(minWidth: 62).padding(.vertical, 4).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.accentColor.opacity(0.16) : (hover ? Color.primary.opacity(0.08) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

/// Botón de la cinta que despliega un menú en un popover (mantiene el icono sobre el texto).
struct RibbonMenu<Content: View>: View {
    let icon: String, label: String
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        RibbonButton(icon: icon, label: label, help: label, active: shown) { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) { content }
                    .buttonStyle(PopoverItemStyle(dismiss: { shown = false }))
                    .padding(8).frame(minWidth: 190)
            }
    }
}

struct PopoverItemStyle: ButtonStyle {
    let dismiss: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? Color.accentColor.opacity(0.25) : Color.clear))
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { if !$0 { dismiss() } }
    }
}
