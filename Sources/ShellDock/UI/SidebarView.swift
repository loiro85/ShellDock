import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var renaming: Folder?
    @State private var folderName = ""
    @State private var importing = false

    var store: SessionStore { state.store }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar sesiones", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            .padding(8)

            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("Sesiones (\(store.sessions.count))") { FolderTree(parent: nil) }
                } else {
                    Section("Resultados") {
                        ForEach(store.search(query)) { s in SessionRow(session: s, showPath: true) }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Button { state.editing = Session() } label: { Label("Sesión", systemImage: "plus") }.help("Nueva sesión")
                Button {
                    folderName = ""
                    renaming = Folder(name: "")
                } label: { Label("Carpeta", systemImage: "folder.badge.plus") }.help("Nueva carpeta")
                Spacer()
                Menu {
                    Button("Exportar sesiones…") { exportSessions() }
                    Button("Importar sesiones (JSON)…") { importing = true }
                    Button("Importar de MobaXterm (.mxtsessions)…") { importing = true }
                } label: { Image(systemName: "square.and.arrow.up.on.square") }
                .menuStyle(.borderlessButton).frame(width: 30).help("Importar / exportar")
            }
            .labelStyle(.titleAndIcon).buttonStyle(.borderless).font(.system(size: 12)).padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .alert("Nueva carpeta", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nombre", text: $folderName)
            Button("Crear") {
                if var f = renaming, !folderName.isEmpty {
                    f.name = folderName
                    store.upsert(folder: f)
                }
                renaming = nil
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data, .text, .plainText]) { r in
            guard case .success(let url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            if url.pathExtension.lowercased() == "mxtsessions" || MobaImporter.looksLikeMoba(data) {
                let n = MobaImporter.importSessions(data, into: store)
                state.flash("Importadas \(n) sesiones")
            } else {
                state.flash("Importadas \(store.importData(data)) sesiones")
            }
        }
    }

    func exportSessions() {
        guard let data = store.exportData() else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "shelldock-sesiones.json"
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let url = p.url { try? data.write(to: url) }
    }
}

struct FolderTree: View {
    @EnvironmentObject var state: AppState
    let parent: UUID?

    var body: some View {
        ForEach(state.store.childFolders(of: parent)) { f in
            FolderRow(folder: f)
        }
        ForEach(state.store.childSessions(of: parent)) { s in
            SessionRow(session: s, showPath: false)
        }
    }
}

struct FolderRow: View {
    @EnvironmentObject var state: AppState
    let folder: Folder

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { folder.expanded }, set: { v in var f = folder; f.expanded = v; state.store.upsert(folder: f) })) {
            AnyView(FolderTree(parent: folder.id))
        } label: {
            Label(folder.name, systemImage: "folder").foregroundStyle(folder.colorHex.map { Color(nsColor: NSColor(hex: $0)) } ?? .primary)
        }
        .dropDestination(for: String.self) { items, _ in
            for it in items { if let id = UUID(uuidString: it), var s = state.store.session(id) { s.folderID = folder.id; state.store.upsert(session: s) } }
            return true
        }
        .contextMenu {
            Button("Abrir todas las sesiones de la carpeta") {
                for s in state.store.childSessions(of: folder.id) { state.open(session: s) }
            }
            Button("Nueva sesión aquí…") { var s = Session(); s.folderID = folder.id; state.editing = s }
            Button("Nueva subcarpeta") { state.store.upsert(folder: Folder(name: "Subcarpeta", parentID: folder.id)) }
            Menu("Color") {
                Button("Ninguno") { var f = folder; f.colorHex = nil; state.store.upsert(folder: f) }
                ForEach(Palette.colors, id: \.self) { h in Button(Palette.name(h)) { var f = folder; f.colorHex = h; state.store.upsert(folder: f) } }
            }
            Divider()
            Button("Eliminar carpeta", role: .destructive) { state.store.delete(folder: folder.id) }
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var state: AppState
    let session: Session
    let showPath: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.kind.symbol).frame(width: 18)
                .foregroundStyle(session.colorHex.map { Color(nsColor: NSColor(hex: $0)) } ?? .accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).lineLimit(1)
                Text(showPath && session.folderID != nil ? "\(state.store.folderPath(session.folderID)) · \(session.displayAddress)" : session.displayAddress)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.open(session: session) }
        .draggable(session.id.uuidString)
        .contextMenu {
            Button("Conectar") { state.open(session: session) }
            Button("Editar…") { state.editing = session }
            Button("Duplicar") { if let c = state.store.duplicate(session: session.id) { state.editing = c } }
            if !state.store.folders.isEmpty {
                Menu("Mover a carpeta") {
                    Button("(raíz)") { var s = session; s.folderID = nil; state.store.upsert(session: s) }
                    ForEach(state.store.folders) { f in Button(state.store.folderPath(f.id)) { var s = session; s.folderID = f.id; state.store.upsert(session: s) } }
                }
            }
            Button("Copiar comando ssh") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SSHLauncher.spec(for: session, settings: state.settings.data).display, forType: .string)
            }
            Divider()
            Button("Eliminar", role: .destructive) { state.store.delete(session: session.id) }
        }
    }
}
