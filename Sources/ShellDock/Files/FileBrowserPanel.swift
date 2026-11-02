import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserPanel: View {
    let session: Session
    let tab: TerminalTab
    @EnvironmentObject var state: AppState
    @StateObject private var model: FileBrowserModel
    @State private var renameTarget: RemoteFile?
    @State private var renameText = ""
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var permTarget: RemoteFile?
    @State private var dropTargeted = false

    init(session: Session, tab: TerminalTab, direct: Bool = false) {
        self.session = session
        self.tab = tab
        _model = StateObject(wrappedValue: FileBrowserModel(session: session, hostKeyPolicy: "accept-new", direct: direct))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !model.transfers.isEmpty { Divider(); transfers }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .onAppear {
            model.terminalSend = { [weak tab] text in tab?.sendText(text) }
            model.useInternalEditor = state.settings.data.internalEditor
            if model.state == .waiting { model.start() }
        }
        .onDisappear { }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.upload([url]) } }
                }
            }
            return true
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(4) } }
        .alert("Renombrar", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Nombre", text: $renameText)
            Button("Renombrar") { if let f = renameTarget, !renameText.isEmpty { model.rename(f, to: renameText) }; renameTarget = nil }
            Button("Cancelar", role: .cancel) { renameTarget = nil }
        }
        .alert("Nueva carpeta", isPresented: $newFolder) {
            TextField("Nombre", text: $folderName)
            Button("Crear") { if !folderName.isEmpty { model.makeFolder(folderName) } }
            Button("Cancelar", role: .cancel) {}
        }
        .sheet(item: $model.editorDoc) { doc in
            TextEditorSheet(doc: doc) { text in model.saveEditor(doc, text: text) }
        }
        .sheet(item: $permTarget) { f in PermissionsSheet(file: f) { mode in model.chmod(f, mode: mode) } }
    }

    var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }.help("Atrás")
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }.help("Carpeta superior")
                Button { model.goHome() } label: { Image(systemName: "house") }.help("Carpeta personal")
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Actualizar")
                Spacer()
                Button { model.chooseUpload() } label: { Image(systemName: "square.and.arrow.up") }.help("Subir archivos…")
                Button { model.chooseDownloadFolder(for: selected) } label: { Image(systemName: "square.and.arrow.down") }.help("Descargar selección…").disabled(selected.isEmpty)
                Button { folderName = ""; newFolder = true } label: { Image(systemName: "folder.badge.plus") }.help("Nueva carpeta")
                Button { model.showHidden.toggle() } label: { Image(systemName: model.showHidden ? "eye" : "eye.slash") }.help("Mostrar archivos ocultos")
            }
            .buttonStyle(.borderless).disabled(model.state != .ready)
            TextField("Ruta", text: Binding(get: { model.path }, set: { model.path = $0 }))
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                .onSubmit { Task { await model.navigate(to: model.path) } }
                .disabled(model.state != .ready)
        }.padding(8)
    }

    var selected: [RemoteFile] { model.entries.filter { model.selection.contains($0.id) } }

    @ViewBuilder var content: some View {
        switch model.state {
        case .waiting:
            VStack(spacing: 10) { ProgressView(); Text("Esperando la conexión SSH…").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connecting:
            VStack(spacing: 10) { ProgressView(); Text("Abriendo SFTP…").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                Text(m).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Reintentar") { model.start() }
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    ForEach(model.visibleEntries) { f in row(f).tag(f.id) }
                }
                .listStyle(.inset)
                .overlay { if model.loading { ProgressView().controlSize(.small) } }
                if let m = model.message {
                    Text(m).font(.caption).foregroundStyle(.red).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func row(_ f: RemoteFile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: f.isDirectory ? "folder.fill" : (f.isSymlink ? "link" : "doc")).foregroundStyle(f.isDirectory ? Color.accentColor : .secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(f.name).lineLimit(1).font(.system(size: 12))
                Text("\(f.permissionString)  \(f.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file) + "  ")\(f.mtime.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(f) }
        .contextMenu {
            let targets = model.selection.contains(f.id) ? selected : [f]
            Button(f.isDirectory ? "Abrir" : "Editar / abrir") { model.open(f) }
            Button("Descargar…") { model.chooseDownloadFolder(for: targets) }
            Divider()
            Button("Renombrar…") { renameText = f.name; renameTarget = f }
            Button("Permisos…") { permTarget = f }
            Button("Copiar ruta") { model.copyPath(f) }
            Button("Ir ahí en el terminal (cd)") { model.cdInTerminal(f) }
            Divider()
            Button("Eliminar", role: .destructive) { model.delete(targets) }
        }
    }

    var transfers: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transferencias").font(.caption.bold())
                Spacer()
                Button("Limpiar") { model.clearFinished() }.buttonStyle(.borderless).font(.caption)
            }
            ForEach(model.transfers.suffix(5)) { t in
                HStack(spacing: 6) {
                    Image(systemName: t.direction == .upload ? "arrow.up.circle" : "arrow.down.circle").font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name).font(.system(size: 10)).lineLimit(1)
                        if let e = t.error { Text(e).font(.system(size: 9)).foregroundStyle(.red).lineLimit(1) }
                        else { ProgressView(value: t.fraction).controlSize(.small) }
                    }
                    if !t.finished { Button { model.cancel(t) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless) }
                    else if t.error == nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                }
            }
        }.padding(8)
    }
}

struct PermissionsSheet: View {
    let file: RemoteFile
    let onApply: (UInt32) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var bits: [Bool]
    @State private var octal: String

    init(file: RemoteFile, onApply: @escaping (UInt32) -> Void) {
        self.file = file
        self.onApply = onApply
        let p = file.permissions
        _bits = State(initialValue: [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001].map { p & $0 != 0 })
        _octal = State(initialValue: String(p & 0o7777, radix: 8))
    }

    var mode: UInt32 { zip(bits, [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001] as [UInt32]).reduce(0) { $0 | ($1.0 ? $1.1 : 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permisos de \(file.name)").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 20) {
                GridRow { Text(""); Text("Leer"); Text("Escribir"); Text("Ejecutar") }.font(.caption).foregroundStyle(.secondary)
                ForEach(0..<3, id: \.self) { r in
                    GridRow {
                        Text(["Propietario", "Grupo", "Otros"][r])
                        ForEach(0..<3, id: \.self) { c in Toggle("", isOn: $bits[r * 3 + c]).labelsHidden().onChange(of: bits) { _ in octal = String(mode, radix: 8) } }
                    }
                }
            }
            HStack {
                Text("Octal:")
                TextField("755", text: $octal).frame(width: 70).onSubmit {
                    if let v = UInt32(octal, radix: 8) { bits = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001].map { v & $0 != 0 } }
                }
            }
            HStack { Spacer(); Button("Cancelar") { dismiss() }; Button("Aplicar") { onApply(UInt32(octal, radix: 8) ?? mode); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 340)
    }
}
