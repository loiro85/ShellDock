import SwiftUI

struct NetworkToolsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var page = 0
    @State private var tool: NetworkTool = .ping
    @State private var host = ""
    @StateObject private var stream = CommandStream()
    // escáner
    @State private var scanHost = "127.0.0.1"
    @State private var portSpec = "1-1024"
    @State private var scanning = false
    @State private var scanProgress = 0.0
    @State private var openPorts: [Int] = []
    @State private var scanTask: Task<Void, Never>?
    // escáner de red
    @State private var cidr = ""
    @State private var netHosts: [HostScanner.Host] = []
    @State private var netScanning = false
    @State private var netProgress = 0.0
    @State private var netTask: Task<Void, Never>?
    // WoL
    @State private var mac = ""
    @State private var wolMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Herramientas de red", systemImage: "network").font(.title3.bold())
                Spacer()
                Button("Cerrar") { stream.stop(); scanTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Picker("", selection: $page) {
                Text("Diagnóstico").tag(0); Text("Escáner de puertos").tag(1); Text("Escáner de red").tag(3); Text("Wake-on-LAN").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            Group {
                switch page {
                case 1: scanner
                case 2: wol
                case 3: networkScanner
                default: diagnostics
                }
            }.padding(16)
        }.frame(width: 800, height: 540)
    }

    var diagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Herramienta", selection: $tool) { ForEach(NetworkTool.allCases) { Text($0.title).tag($0) } }.frame(width: 260)
                if tool.needsHost { TextField("host o IP", text: $host).textFieldStyle(.roundedBorder).onSubmit { run() } }
                Spacer()
                if stream.running { Button("Detener") { stream.stop() } } else { Button("Ejecutar") { run() }.keyboardShortcut(.defaultAction).disabled(tool.needsHost && host.isEmpty) }
            }
            ScrollView {
                Text(stream.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    func run() {
        let (e, a) = tool.command(host: host.trimmingCharacters(in: .whitespaces))
        stream.run(e, a)
    }

    var scanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("host o IP", text: $scanHost).textFieldStyle(.roundedBorder)
                TextField("puertos: 22,80,8000-8100", text: $portSpec).textFieldStyle(.roundedBorder)
                if scanning { Button("Detener") { scanTask?.cancel(); scanning = false } }
                else { Button("Escanear") { startScan() }.keyboardShortcut(.defaultAction).disabled(scanHost.isEmpty) }
            }
            if scanning { ProgressView(value: scanProgress) }
            List(openPorts, id: \.self) { p in
                HStack {
                    Image(systemName: "circle.fill").foregroundStyle(.green).font(.system(size: 8))
                    Text("\(p)/tcp").font(.system(.body, design: .monospaced))
                    Text(PortScanner.services[p] ?? "").foregroundStyle(.secondary)
                }
            }
            Text(scanning ? "Escaneando…" : "\(openPorts.count) puertos abiertos").font(.caption).foregroundStyle(.secondary)
        }
    }

    func startScan() {
        let ports = PortScanner.parsePorts(portSpec)
        guard !ports.isEmpty else { return }
        scanning = true
        openPorts = []
        scanProgress = 0
        let h = scanHost.trimmingCharacters(in: .whitespaces)
        scanTask = Task {
            let found = await PortScanner.scan(host: h, ports: ports) { d, t in Task { @MainActor in scanProgress = Double(d) / Double(max(t, 1)) } }
            await MainActor.run { openPorts = found; scanning = false }
        }
    }

    var networkScanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Red, p. ej. 192.168.1.0/24", text: $cidr).textFieldStyle(.roundedBorder)
                if netScanning { Button("Detener") { netTask?.cancel(); netScanning = false } }
                else { Button("Buscar equipos") { startNetScan() }.keyboardShortcut(.defaultAction).disabled(HostScanner.addresses(cidr: cidr) == nil) }
            }
            if netScanning { ProgressView(value: netProgress) }
            List(netHosts) { h in
                HStack {
                    Image(systemName: "desktopcomputer").foregroundStyle(.green)
                    Text(h.ip).font(.system(.body, design: .monospaced)).frame(width: 130, alignment: .leading)
                    Text(h.name).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(h.mac).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Button("Escanear puertos") { scanHost = h.ip; page = 1 }.buttonStyle(.borderless).font(.caption)
                }
            }
            Text(netScanning ? "Buscando…" : (HostScanner.addresses(cidr: cidr) == nil && !cidr.isEmpty ? "Red no válida o demasiado grande (máximo /22)" : "\(netHosts.count) equipos responden")).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if cidr.isEmpty { cidr = Self.guessLocalNetwork() } }
    }

    func startNetScan() {
        netScanning = true; netHosts = []; netProgress = 0
        let c = cidr
        netTask = Task {
            let found = await HostScanner.scan(cidr: c) { d, t in Task { @MainActor in netProgress = Double(d) / Double(max(t, 1)) } }
            await MainActor.run { netHosts = found; netScanning = false }
        }
    }

    /// Red /24 de la primera interfaz Ethernet/Wi-Fi activa.
    static func guessLocalNetwork() -> String {
        let ip = ServersView.localIP()
        let p = ip.split(separator: ".")
        return p.count == 4 ? "\(p[0]).\(p[1]).\(p[2]).0/24" : "192.168.1.0/24"
    }

    var wol: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enciende un equipo de la red local enviando un «paquete mágico» a su dirección MAC.").foregroundStyle(.secondary)
            HStack {
                TextField("MAC: AA:BB:CC:DD:EE:FF", text: $mac).textFieldStyle(.roundedBorder).frame(width: 300)
                Button("Enviar") { wolMessage = WakeOnLAN.send(mac: mac) ? "Paquete enviado" : "MAC no válida o envío fallido" }.disabled(mac.isEmpty)
            }
            Text(wolMessage).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
