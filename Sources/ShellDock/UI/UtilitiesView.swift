import SwiftUI
import AppKit

struct UtilitiesView: View {
    @Environment(\.dismiss) var dismiss
    @State private var tab = 0
    @State private var input = ""
    @State private var length = 20
    @State private var upper = true
    @State private var lower = true
    @State private var digits = true
    @State private var symbols = true
    @State private var generated = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Utilidades", systemImage: "hammer").font(.title3.bold())
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Picker("", selection: $tab) {
                Text("Contraseñas").tag(0); Text("Hashes").tag(1); Text("Base64 / URL / Hex").tag(2); Text("Subred").tag(3); Text("Fecha Unix").tag(4)
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case 0: passwords
                case 1: hashes
                case 2: encodings
                case 3: subnet
                default: epoch
                }
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(width: 640, height: 460)
    }

    func copyButton(_ s: String) -> some View {
        Button("Copiar") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }.disabled(s.isEmpty)
    }

    var passwords: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(tr("Longitud: %@", "\(length)"), value: $length, in: 4...128)
            HStack { Toggle("A-Z", isOn: $upper); Toggle("a-z", isOn: $lower); Toggle("0-9", isOn: $digits); Toggle("Símbolos", isOn: $symbols) }
            HStack {
                Button("Generar") { generated = Utilities.password(length: length, upper: upper, lower: lower, digits: digits, symbols: symbols) }.keyboardShortcut(.defaultAction)
                copyButton(generated)
            }
            Text(generated).font(.system(size: 16, design: .monospaced)).textSelection(.enabled).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
        }
    }

    var inputBox: some View {
        TextEditor(text: $input).font(.system(size: 13, design: .monospaced)).frame(height: 110)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.2)))
    }

    var hashes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Texto").font(.caption).foregroundStyle(.secondary)
            inputBox
            ForEach(Utilities.hashes(of: Data(input.utf8)), id: \.0) { n, h in
                HStack(alignment: .top) {
                    Text(n).font(.caption.bold()).frame(width: 60, alignment: .leading)
                    Text(h).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }

    var encodings: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputBox
            row("Base64", Utilities.base64Encode(input), Utilities.base64Decode(input))
            row("URL", Utilities.urlEncode(input), Utilities.urlDecode(input))
            row("Hex", Utilities.hexEncode(input), Utilities.hexDecode(input))
        }
    }

    func row(_ name: String, _ enc: String, _ dec: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tr("%@ codificado", "\(name)")).font(.caption).foregroundStyle(.secondary)
            Text(enc).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Text(tr("%@ decodificado", "\(name)")).font(.caption).foregroundStyle(.secondary)
            Text(dec ?? tr("(no válido)")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
        }
    }

    var subnet: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("CIDR, p. ej. 192.168.1.0/24", text: $input).textFieldStyle(.roundedBorder)
            if let s = Utilities.subnet(input) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Red"); Text(s.network) }
                    GridRow { Text("Máscara"); Text(s.mask) }
                    GridRow { Text("Wildcard"); Text(s.wildcard) }
                    GridRow { Text("Broadcast"); Text(s.broadcast) }
                    GridRow { Text("Primer host"); Text(s.first) }
                    GridRow { Text("Último host"); Text(s.last) }
                    GridRow { Text("Hosts útiles"); Text("\(s.hosts)") }
                }.font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            } else { Text("Escribe una red IPv4 con prefijo").foregroundStyle(.secondary) }
        }
    }

    var epoch: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Segundos o milisegundos desde 1970", text: $input).textFieldStyle(.roundedBorder)
            Text(Utilities.epochToDate(input) ?? "—").font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            Button(tr("Ahora: %@", "\(Int(Date().timeIntervalSince1970))")) { input = String(Int(Date().timeIntervalSince1970)) }
        }
    }
}

struct ServersView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Public")
    @State private var port = 8000
    @State private var error = ""
    @State private var lan = false

    var server: HTTPFileServer { state.httpServer }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Servidor HTTP", systemImage: "externaldrive.connected.to.line.below").font(.title3.bold())
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Publica una carpeta en tu red (solo lectura) para descargar archivos desde otras máquinas con curl o wget.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(folder.path).lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
                Button("Elegir…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    if p.runModal() == .OK, let u = p.url { folder = u }
                }.disabled(server.running)
            }
            Toggle("Accesible desde la red local (sin contraseña: cualquiera en tu red podrá leer esa carpeta)", isOn: $lan).disabled(server.running).font(.caption)
            HStack {
                TextField("Puerto", value: $port, format: .number.grouping(.never)).frame(width: 110).disabled(server.running)
                if server.running {
                    Button("Detener") { server.stop() }
                    Text("http://\(lan ? Self.localIP() : "127.0.0.1"):\(server.port)/").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).foregroundStyle(.green)
                } else {
                    Button("Iniciar") {
                        do { try server.start(folder: folder, port: UInt16(clamping: port), localOnly: !lan); error = "" } catch let e { error = e.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            ScrollView { Text(server.log.suffix(100).joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.2)))
        }.padding(16).frame(width: 560, height: 380)
    }

    static func localIP() -> String {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return "localhost" }
        defer { freeifaddrs(addrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            if i.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: i.pointee.ifa_name).hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(i.pointee.ifa_addr, socklen_t(i.pointee.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            p = i.pointee.ifa_next
        }
        return "localhost"
    }
}

struct LockView: View {
    @EnvironmentObject var state: AppState
    @State private var pw = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("ShellDock está bloqueado").font(.title3.bold())
            SecureField("Contraseña maestra", text: $pw).textFieldStyle(.roundedBorder).frame(width: 260).onSubmit(unlock)
            if wrong { Text("Contraseña incorrecta").foregroundStyle(.red).font(.caption) }
            Button("Desbloquear", action: unlock).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }

    func unlock() {
        if MasterPassword.verify(pw) { state.locked = false; pw = ""; wrong = false } else { wrong = true; pw = "" }
    }
}
