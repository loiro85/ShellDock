import SwiftUI

struct TunnelsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var editing: SavedTunnel?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Túneles SSH", systemImage: "arrow.left.arrow.right.circle").font(.title3.bold())
                Spacer()
                Button { editing = SavedTunnel(sessionID: state.store.sessions.first { $0.kind == .ssh }?.id) } label: { Label("Nuevo túnel", systemImage: "plus") }
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if state.store.savedTunnels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Aún no hay túneles").font(.headline)
                    Text("Un túnel redirige un puerto local a un servicio remoto (o al revés) a través de una sesión SSH.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.store.savedTunnels) { t in TunnelRow(tunnel: t) { editing = t } }
                }
            }
        }
        .frame(width: 640, height: 460)
        .sheet(item: $editing) { t in TunnelEditor(tunnel: t) }
    }
}

struct TunnelRow: View {
    let tunnel: SavedTunnel
    let edit: () -> Void
    @EnvironmentObject var state: AppState

    var session: Session? { tunnel.sessionID.flatMap { state.store.session($0) } }
    var st: TunnelManager.State { state.tunnels.state(tunnel.id) }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name.isEmpty ? tunnel.tunnel.kind.title : tunnel.name).font(.system(size: 13, weight: .semibold))
                Text("\(session?.name ?? "(sin sesión)") · \(tunnel.tunnel.summary)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                if case .failed(let m) = st { Text(m).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }
            Spacer()
            Text(st.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 120, alignment: .trailing)
            Toggle("", isOn: Binding(get: { st == .running || st == .starting }, set: { on in
                guard let s = session else { return }
                if on { state.tunnels.start(tunnel, session: s, hostKeyPolicy: state.settings.data.hostKeyPolicy) } else { state.tunnels.stop(tunnel.id) }
            })).toggleStyle(.switch).labelsHidden().disabled(session == nil)
            Button { edit() } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
            Button(role: .destructive) { state.tunnels.stop(tunnel.id); state.store.savedTunnels.removeAll { $0.id == tunnel.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }.padding(.vertical, 3)
    }

    var color: Color {
        switch st { case .running: return .green; case .starting: return .orange; case .failed: return .red; case .stopped: return .gray }
    }
}

struct TunnelEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State var tunnel: SavedTunnel

    init(tunnel: SavedTunnel) { _tunnel = State(initialValue: tunnel) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nombre", text: $tunnel.name)
                Picker("Sesión SSH", selection: $tunnel.sessionID) {
                    Text("Elegir…").tag(UUID?.none)
                    ForEach(state.store.sessions.filter { $0.kind == .ssh }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Picker("Tipo", selection: $tunnel.tunnel.kind) { ForEach(TunnelKind.allCases) { Text($0.title).tag($0) } }
                HStack {
                    TextField("Escuchar en", text: $tunnel.tunnel.bindHost)
                    TextField("Puerto", value: $tunnel.tunnel.bindPort, format: .number.grouping(.never)).frame(width: 90)
                }
                if tunnel.tunnel.kind != .dynamic {
                    HStack {
                        TextField("Destino", text: $tunnel.tunnel.targetHost)
                        TextField("Puerto", value: $tunnel.tunnel.targetPort, format: .number.grouping(.never)).frame(width: 90)
                    }
                }
                Text(tunnel.tunnel.summary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Guardar") {
                    if let i = state.store.savedTunnels.firstIndex(where: { $0.id == tunnel.id }) { state.store.savedTunnels[i] = tunnel } else { state.store.savedTunnels.append(tunnel) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(tunnel.sessionID == nil)
            }.padding(16)
        }.frame(width: 480, height: 400)
    }
}
