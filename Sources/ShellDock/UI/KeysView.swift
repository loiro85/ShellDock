import SwiftUI

struct KeysView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var keys: [SSHKeyInfo] = []
    @State private var selection: String?
    @State private var showNew = false
    @State private var message = ""

    var selected: SSHKeyInfo? { keys.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Claves SSH", systemImage: "key").font(.title3.bold())
                Spacer()
                Button { showNew = true } label: { Label("Generar clave", systemImage: "plus") }
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            HSplitView {
                List(keys, selection: $selection) { k in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(k.name).font(.system(size: 13, weight: .semibold))
                        Text("\(k.type) \(k.bits) · \(k.comment)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(k.id)
                }.frame(minWidth: 220, maxWidth: 280)
                detail.frame(minWidth: 380)
            }
            if !message.isEmpty { Divider(); Text(message).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .frame(width: 780, height: 480)
        .onAppear { reload() }
        .sheet(isPresented: $showNew) { NewKeySheet { reload($0) } }
    }

    func reload(_ select: String? = nil) {
        keys = SSHKeys.list()
        if let s = select { selection = s } else if selection == nil { selection = keys.first?.id }
    }

    @ViewBuilder var detail: some View {
        if let k = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(k.name).font(.title3.bold())
                    Group {
                        row("Tipo", "\(k.type) \(k.bits)")
                        row("Huella", k.fingerprint)
                        row("Comentario", k.comment)
                        row("Ruta", k.path)
                    }
                    if let pub = SSHKeys.publicKey(k) {
                        Text("Clave pública").font(.caption.bold())
                        Text(pub).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(8)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                    HStack {
                        Button("Copiar clave pública") {
                            if let p = SSHKeys.publicKey(k) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p, forType: .string); message = "Clave pública copiada" }
                        }.disabled(!k.hasPublic)
                        Button("Añadir al agente") {
                            let (st, o) = SSHKeys.run("/usr/bin/ssh-add", ["--apple-use-keychain", k.path])
                            message = st == 0 ? "Añadida al agente y al Llavero" : o
                        }
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: k.path)]) }
                    }
                    Menu("Instalar en un servidor…") {
                        ForEach(state.store.sessions.filter { $0.kind == .ssh }) { s in
                            Button(s.name) { installKey(k, on: s) }
                        }
                    }.disabled(!k.hasPublic || state.store.sessions.filter { $0.kind == .ssh }.isEmpty)
                    Divider()
                    Button("Eliminar clave", role: .destructive) {
                        try? FileManager.default.removeItem(atPath: k.path)
                        try? FileManager.default.removeItem(atPath: k.publicPath)
                        selection = nil
                        reload()
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("No hay claves en ~/.ssh").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).foregroundStyle(.secondary).frame(width: 90, alignment: .leading); Text(v).textSelection(.enabled) }.font(.system(size: 12))
    }

    /// `ssh-copy-id` en una pestaña local para poder teclear la contraseña del servidor.
    func installKey(_ k: SSHKeyInfo, on s: Session) {
        var args = ["-i", k.publicPath]
        if s.port != 22 { args += ["-p", String(s.port)] }
        args.append(s.username.isEmpty ? s.host : "\(s.username)@\(s.host)")
        let tab = ProcessTab(title: "ssh-copy-id \(s.name)", kind: .local) {
            LaunchSpec(executable: "/usr/bin/ssh-copy-id", args: args, env: ProcessEnvironment.base(), cwd: NSHomeDirectory(), display: "ssh-copy-id")
        }
        state.add(tab)
        dismiss()
    }
}

struct NewKeySheet: View {
    @Environment(\.dismiss) var dismiss
    let onDone: (String) -> Void
    @State private var name = "id_ed25519_nueva"
    @State private var type = "ed25519"
    @State private var bits = 4096
    @State private var comment = "\(NSUserName())@\(Host.current().localizedName ?? "mac")"
    @State private var pass = ""
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nombre del archivo", text: $name)
                Picker("Tipo", selection: $type) { Text("Ed25519 (recomendado)").tag("ed25519"); Text("RSA").tag("rsa"); Text("ECDSA").tag("ecdsa") }
                if type == "rsa" { Picker("Bits", selection: $bits) { Text("3072").tag(3072); Text("4096").tag(4096) } }
                if type == "ecdsa" { Picker("Bits", selection: $bits) { Text("256").tag(256); Text("384").tag(384); Text("521").tag(521) } }
                TextField("Comentario", text: $comment)
                SecureField("Frase de paso (opcional)", text: $pass)
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Generar") {
                    let (ok, out) = SSHKeys.generate(name: name, type: type, bits: type == "ed25519" ? nil : bits, comment: comment, passphrase: pass)
                    if ok { onDone(SSHKeys.sshDir + "/" + name); dismiss() } else { error = out }
                }.keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }.padding(16)
        }.frame(width: 460, height: 360)
        .onChange(of: type) { t in bits = t == "rsa" ? 4096 : (t == "ecdsa" ? 384 : bits) }
    }
}
