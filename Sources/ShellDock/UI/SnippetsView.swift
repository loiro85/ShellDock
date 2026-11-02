import SwiftUI

struct SnippetsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selection: UUID?
    @State private var sendToAll = false

    var snippet: Binding<Snippet>? {
        guard let id = selection, let i = state.store.snippets.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { state.store.snippets[i] }, set: { state.store.snippets[i] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Snippets y macros", systemImage: "text.badge.plus").font(.title3.bold())
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(state.store.snippets) { s in
                            Label(s.name, systemImage: "doc.text").tag(s.id)
                                .contextMenu { Button("Eliminar", role: .destructive) { state.store.snippets.removeAll { $0.id == s.id } } }
                        }
                    }
                    Divider()
                    HStack {
                        Button { let n = Snippet(); state.store.snippets.append(n); selection = n.id } label: { Label("Nuevo", systemImage: "plus") }.buttonStyle(.borderless)
                        Spacer()
                    }.padding(8)
                }.frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
                Group {
                    if let b = snippet {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Nombre", text: b.name).textFieldStyle(.roundedBorder)
                            Text("Contenido (varias líneas = varios comandos)").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: b.text).font(.system(.body, design: .monospaced)).border(Color.gray.opacity(0.3))
                            Toggle("Pulsar Intro al final", isOn: b.sendReturn)
                            Text("Variables: ${host} ${user} ${session} ${date} ${time} ${clipboard}   ·   Pausa: línea «#wait 2»").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Toggle("Enviar a todas las pestañas de MultiExec", isOn: $sendToAll)
                                Spacer()
                                Button("Ejecutar en la pestaña activa") { state.run(snippet: b.wrappedValue, toAll: sendToAll) }
                                    .keyboardShortcut(.defaultAction).disabled(state.selectedTab == nil)
                            }
                        }.padding(16)
                    } else {
                        Text("Elige o crea un snippet").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }.frame(width: 760, height: 480)
    }
}
