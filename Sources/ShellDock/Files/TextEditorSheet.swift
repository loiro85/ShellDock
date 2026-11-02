import SwiftUI
import AppKit

struct EditorDoc: Identifiable {
    let id = UUID()
    let name: String
    let remotePath: String
    let local: URL
    let text: String
}

/// Editor de texto integrado para archivos remotos (equivalente al MobaTextEditor).
struct TextEditorSheet: View {
    let doc: EditorDoc
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saved: String
    @State private var confirmClose = false

    init(doc: EditorDoc, onSave: @escaping (String) -> Void) {
        self.doc = doc; self.onSave = onSave
        _text = State(initialValue: doc.text); _saved = State(initialValue: doc.text)
    }

    var dirty: Bool { text != saved }
    var lines: Int { text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                Text(doc.name).font(.headline) + Text(dirty ? "  ● sin guardar" : "").foregroundColor(.orange)
                Text(doc.remotePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Guardar") { onSave(text); saved = text }.keyboardShortcut("s", modifiers: .command).disabled(!dirty)
                Button("Cerrar") { if dirty { confirmClose = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
            }.padding(10)
            Divider()
            TextEditor(text: $text).font(.system(size: 13, design: .monospaced))
            Divider()
            HStack { Text("\(lines) líneas · \(text.utf8.count) bytes · UTF-8"); Spacer() }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
        }
        .frame(minWidth: 720, minHeight: 480)
        .confirmationDialog("Hay cambios sin guardar", isPresented: $confirmClose) {
            Button("Guardar y cerrar") { onSave(text); dismiss() }
            Button("Descartar cambios", role: .destructive) { dismiss() }
            Button("Cancelar", role: .cancel) {}
        }
    }
}
