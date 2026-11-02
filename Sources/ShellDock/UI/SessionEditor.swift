import SwiftUI
import UniformTypeIdentifiers

struct SessionEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State var session: Session
    @State private var password = ""
    @State private var passphrase = ""
    @State private var tab = 0
    @State private var newTunnel = Tunnel()

    init(session: Session) { _session = State(initialValue: session) }

    var isNew: Bool { !state.store.sessions.contains { $0.id == session.id } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: session.kind.symbol).font(.title2).foregroundStyle(.tint)
                Text(isNew ? "Nueva sesión" : "Editar sesión").font(.title3.bold())
                Spacer()
            }.padding([.horizontal, .top], 16)

            Picker("", selection: $tab) {
                Text("General").tag(0)
                if session.kind == .ssh || session.kind == .sftp { Text("SSH avanzado").tag(1) }
                if session.kind == .ssh { Text("Túneles").tag(2) }
                Text("Apariencia").tag(3)
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 10)

            Form {
                switch tab {
                case 1: advancedSection
                case 2: tunnelsSection
                case 3: appearanceSection
                default: generalSection
                }
            }.formStyle(.grouped)

            HStack {
                if !isNew { Button("Eliminar", role: .destructive) { state.store.delete(session: session.id); dismiss() } }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") { save(connect: false) }
                Button("Guardar y conectar") { save(connect: true) }.keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }.padding(16)
        }
        .frame(width: 600, height: 640)
        .onAppear {
            if session.hasStoredPassword { password = "••••••••" }
            if session.hasStoredPassphrase { passphrase = "••••••••" }
        }
    }

    var valid: Bool {
        !session.name.isEmpty && (!session.kind.needsHost || !session.host.trimmingCharacters(in: .whitespaces).isEmpty)
            && (session.kind != .serial || !session.serial.device.isEmpty)
    }

    func save(connect: Bool) {
        var s = session
        if password != "••••••••" { state.store.setPassword(password, for: &s) }
        if passphrase != "••••••••" { state.store.setPassphrase(passphrase, for: &s) }
        state.store.upsert(session: s)
        dismiss()
        if connect { DispatchQueue.main.async { state.open(session: s) } }
    }

    // MARK: secciones

    var generalSection: some View {
        Group {
            Section("Sesión") {
                Picker("Tipo", selection: $session.kind) {
                    ForEach(SessionKind.allCases) { k in Label(k.title, systemImage: k.symbol).tag(k) }
                }
                .onChange(of: session.kind) { k in if k.needsHost { session.port = k.defaultPort } }
                TextField("Nombre", text: $session.name)
                Picker("Carpeta", selection: $session.folderID) {
                    Text("(raíz)").tag(UUID?.none)
                    ForEach(state.store.folders) { f in Text(state.store.folderPath(f.id)).tag(UUID?.some(f.id)) }
                }
                Picker("Color", selection: Binding(get: { session.colorHex ?? "" }, set: { session.colorHex = $0.isEmpty ? nil : $0 })) {
                    Text("Ninguno").tag("")
                    ForEach(Palette.colors, id: \.self) { Text(Palette.name($0)).tag($0) }
                }
            }
            if session.kind.needsHost {
                Section("Servidor") {
                    TextField(session.kind == .browser ? "Dirección web (https://…)" : "Host o IP", text: $session.host)
                    HStack {
                        TextField("Puerto", value: $session.port, format: .number.grouping(.never)).frame(width: 140)
                        Spacer()
                    }
                    TextField("Usuario", text: $session.username)
                }
            }
            if session.kind == .ssh || session.kind == .sftp {
                Section("Autenticación") {
                    Picker("Método", selection: $session.auth) { ForEach(AuthMethod.allCases) { Text($0.title).tag($0) } }
                    SecureField("Contraseña (se guarda en el Llavero)", text: $password)
                    HStack {
                        TextField("Clave privada", text: $session.keyPath)
                        Button("Elegir…") { chooseKey() }
                    }
                    SecureField("Frase de paso de la clave (Llavero)", text: $passphrase)
                }
            }
            if session.kind == .ftp {
                Section("FTP") {
                    SecureField("Contraseña (Llavero)", text: $password)
                    Toggle("Cifrar con TLS (FTPS)", isOn: $session.ftpTLS)
                }
            }
            if session.kind == .serial { serialSection }
            if session.kind == .miniLinux {
                Section("Mini Linux (Alpine en una máquina virtual)") {
                    Stepper(session.vmMemoryMB == 0 ? "Memoria: 1024 MB (predeterminado)" : "Memoria: \(session.vmMemoryMB) MB", value: $session.vmMemoryMB, in: 0...16384, step: 256)
                    Stepper(session.vmCPUs == 0 ? "CPUs: automático" : "CPUs: \(session.vmCPUs)", value: $session.vmCPUs, in: 0...8)
                    TextField("Carpeta compartida con el Mac (vacío = ~/ShellDock-Linux)", text: $session.sharedFolder)
                    Text("La carpeta se ve dentro de Linux en /mnt/mac. El sistema vive en memoria: lo que guardes fuera de esa carpeta se pierde al apagar.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if session.kind == .rdp {
                Section("RDP") {
                    TextField("Dominio", text: $session.rdpDomain)
                    TextField("Resolución (p. ej. 1920x1080)", text: $session.rdpResolution)
                }
            }
            if session.kind == .vnc {
                Section("VNC") { SecureField("Contraseña VNC (Llavero)", text: $password) }
            }
            Section("Notas") { TextEditor(text: $session.notes).frame(height: 54) }
        }
    }

    var serialSection: some View {
        Section("Puerto serie") {
            Picker("Dispositivo", selection: $session.serial.device) {
                Text("Elegir…").tag("")
                ForEach(SerialPorts.list(), id: \.self) { Text($0).tag($0) }
            }
            Picker("Baudios", selection: $session.serial.baud) { ForEach([1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600], id: \.self) { Text("\($0)").tag($0) } }
            Picker("Bits de datos", selection: $session.serial.dataBits) { ForEach([5, 6, 7, 8], id: \.self) { Text("\($0)").tag($0) } }
            Picker("Paridad", selection: $session.serial.parity) { Text("Ninguna").tag("none"); Text("Par").tag("even"); Text("Impar").tag("odd") }
            Picker("Bits de parada", selection: $session.serial.stopBits) { Text("1").tag(1); Text("2").tag(2) }
            Picker("Control de flujo", selection: $session.serial.flow) { Text("Ninguno").tag("none"); Text("RTS/CTS").tag("rtscts"); Text("XON/XOFF").tag("xonxoff") }
        }
    }

    var advancedSection: some View {
        Group {
            Section("Conexión") {
                TextField("Salto (ProxyJump): usuario@bastion[:puerto]", text: $session.jumpHost)
                Stepper("Keep-alive cada \(session.keepAlive) s", value: $session.keepAlive, in: 0...600, step: 5)
                Toggle("Compresión (-C)", isOn: $session.compression)
                Toggle("Reconectar automáticamente si se cae", isOn: $session.autoReconnect)
            }
            Section("Reenvíos") {
                Toggle("Reenvío X11", isOn: $session.x11Forwarding)
                if session.x11Forwarding {
                    Toggle("X11 de confianza (-Y)", isOn: $session.x11Trusted)
                    if !X11.installed { Text("XQuartz no está instalado: instálalo para usar aplicaciones gráficas (brew install --cask xquartz).").font(.caption).foregroundStyle(.orange) }
                }
                Toggle("Reenvío del agente SSH (-A)", isOn: $session.agentForwarding)
            }
            Section("Después de conectar") {
                TextField("Comando inicial", text: $session.startupCommand)
                TextField("Argumentos extra de ssh", text: $session.extraArguments)
                Toggle("Mostrar panel de archivos (SFTP)", isOn: $session.openFileBrowser)
            }
        }
    }

    var tunnelsSection: some View {
        Group {
            Section("Túneles de esta sesión (se abren al conectar)") {
                if session.tunnels.isEmpty { Text("Sin túneles").foregroundStyle(.secondary) }
                ForEach(session.tunnels) { t in
                    HStack {
                        Text(t.name.isEmpty ? t.kind.title : t.name)
                        Spacer()
                        Text(t.summary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Button(role: .destructive) { session.tunnels.removeAll { $0.id == t.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Añadir túnel") {
                Picker("Tipo", selection: $newTunnel.kind) { ForEach(TunnelKind.allCases) { Text($0.title).tag($0) } }
                TextField("Nombre", text: $newTunnel.name)
                HStack {
                    TextField("Escuchar en", text: $newTunnel.bindHost)
                    TextField("Puerto", value: $newTunnel.bindPort, format: .number.grouping(.never)).frame(width: 90)
                }
                if newTunnel.kind != .dynamic {
                    HStack {
                        TextField("Destino", text: $newTunnel.targetHost)
                        TextField("Puerto", value: $newTunnel.targetPort, format: .number.grouping(.never)).frame(width: 90)
                    }
                }
                Button("Añadir") { session.tunnels.append(newTunnel); newTunnel = Tunnel() }
            }
        }
    }

    var appearanceSection: some View {
        Section("Apariencia de esta sesión") {
            Picker("Tema", selection: $session.themeName) {
                Text("Predeterminado").tag("")
                ForEach(TerminalTheme.all) { Text($0.name).tag($0.name) }
            }
            Stepper(session.fontSize == 0 ? "Tamaño de fuente: predeterminado" : "Tamaño de fuente: \(session.fontSize)", value: $session.fontSize, in: 0...40)
        }
    }

    func chooseKey() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.showsHiddenFiles = true
        if p.runModal() == .OK, let u = p.url { session.keyPath = u.path }
    }
}
