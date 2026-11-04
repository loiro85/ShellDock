import Foundation
import Network

/// Ejecuta un comando y emite su salida en tiempo real.
@MainActor
final class CommandStream: ObservableObject {
    @Published var output = ""
    @Published var running = false
    private var process: Process?

    func run(_ executable: String, _ args: [String]) {
        stop()
        output = "$ \(([executable] + args).map(ShellSplit.quote).joined(separator: " "))\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in self?.output += s }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.running = false
                self?.output += "\n[terminado con código \(proc.terminationStatus)]\n"
            }
        }
        do { try p.run(); process = p; running = true }
        catch { output += "No se pudo ejecutar: \(error.localizedDescription)\n" }
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }
}

enum NetworkTool: String, CaseIterable, Identifiable {
    case ping, traceroute, dns, whois, interfaces, routes, connections, arp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ping: return "Ping"
        case .traceroute: return "Traceroute"
        case .dns: return "DNS (dig)"
        case .whois: return "Whois"
        case .interfaces: return "Interfaces de red"
        case .routes: return "Tabla de rutas"
        case .connections: return "Conexiones activas"
        case .arp: return "Tabla ARP"
        }
    }

    var needsHost: Bool { [.ping, .traceroute, .dns, .whois].contains(self) }

    func command(host rawHost: String) -> (String, [String]) {
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        if needsHost, let problem = SessionSafety.toolHostError(host) { return ("/bin/echo", [problem]) }     // nunca se pasa a una orden algo que parezca una opción
        switch self {
        case .ping: return ("/sbin/ping", ["-c", "6", host])
        case .traceroute: return ("/usr/sbin/traceroute", ["-m", "25", "-w", "2", host])
        case .dns: return ("/usr/bin/dig", [host, "ANY", "+noall", "+answer", "+comments"])
        case .whois: return ("/usr/bin/whois", [host])
        case .interfaces: return ("/sbin/ifconfig", [])
        case .routes: return ("/usr/sbin/netstat", ["-rn"])
        case .connections: return ("/usr/sbin/netstat", ["-an", "-p", "tcp"])
        case .arp: return ("/usr/sbin/arp", ["-a"])
        }
    }
}

/// Escáner de puertos TCP concurrente.
enum PortScanner {
    static let services: [Int: String] = [
        20: "ftp-data", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "dns", 80: "http", 110: "pop3", 111: "rpcbind",
        123: "ntp", 135: "msrpc", 139: "netbios", 143: "imap", 161: "snmp", 389: "ldap", 443: "https", 445: "smb",
        465: "smtps", 514: "syslog", 587: "submission", 631: "ipp", 993: "imaps", 995: "pop3s", 1433: "mssql", 1521: "oracle",
        3306: "mysql", 3389: "rdp", 5432: "postgres", 5900: "vnc", 5985: "winrm", 6379: "redis", 8080: "http-alt",
        8443: "https-alt", 9200: "elasticsearch", 27017: "mongodb",
    ]

    /// "22,80,8000-8100" → [22, 80, 8000...8100] (sin duplicados, ordenado, máx. 65535).
    static func parsePorts(_ spec: String) -> [Int] {
        var set = Set<Int>()
        for part in spec.split(whereSeparator: { $0 == "," || $0 == " " }) {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 1, (1...65535).contains(bounds[0]) { set.insert(bounds[0]) }
            else if bounds.count == 2 {
                let lo = max(1, min(bounds[0], bounds[1])), hi = min(65535, max(bounds[0], bounds[1]))
                if lo <= hi { for p in lo...hi { set.insert(p) } }
            }
        }
        return set.sorted()
    }

    static func isOpen(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            let done = ScanOnce()
            func finish(_ v: Bool) { if done.fire() { c.cancel(); cont.resume(returning: v) } }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            c.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private final class ScanOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
    }

    static func scan(host: String, ports: [Int], timeout: TimeInterval = 0.8, concurrency: Int = 200,
                     progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [Int] {
        var open: [Int] = []
        var done = 0
        var index = 0
        await withTaskGroup(of: (Int, Bool).self) { group in
            func next() {
                guard index < ports.count else { return }
                let p = ports[index]
                index += 1
                group.addTask { (p, await isOpen(host: host, port: p, timeout: timeout)) }
            }
            for _ in 0..<min(concurrency, ports.count) { next() }
            while let (p, ok) = await group.next() {
                done += 1
                if ok { open.append(p) }
                progress(done, ports.count)
                next()
            }
        }
        return open.sorted()
    }
}

enum WakeOnLAN {
    /// Paquete mágico: 6×0xFF + 16 repeticiones de la MAC. nil si la MAC no es válida.
    static func magicPacket(mac: String) -> Data? {
        let hex = mac.filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(Array(repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in bytes })
    }

    static func send(mac: String, broadcast: String = "255.255.255.255", port: UInt16 = 9) -> Bool {
        guard let pkt = magicPacket(mac: mac) else { return false }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, broadcast, &addr.sin_addr)
        let n = pkt.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, raw.baseAddress, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        return n == pkt.count
    }
}

/// Descubrimiento de equipos de una subred (barrido de ping + tabla ARP + DNS inverso).
enum HostScanner {
    struct Host: Identifiable, Equatable {
        var ip: String
        var name: String
        var mac: String
        var id: String { ip }
    }

    /// Direcciones a sondear: los hosts útiles de la red (máximo `limit`, para no lanzar barridos enormes sin querer).
    static func addresses(cidr: String, limit: Int = 1022) -> [String]? {
        guard let s = Utilities.subnet(cidr), s.hosts <= UInt64(limit) else { return nil }
        func v(_ ip: String) -> UInt32 { ip.split(separator: ".").compactMap { UInt32($0) }.reduce(0) { $0 << 8 | $1 } }
        return (v(s.first)...v(s.last)).map { "\($0 >> 24).\(($0 >> 16) & 255).\(($0 >> 8) & 255).\($0 & 255)" }
    }

    static func parseARP(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            // "? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]"
            guard let o = line.firstIndex(of: "("), let c = line.firstIndex(of: ")"), o < c, let at = line.range(of: " at ") else { continue }
            let mac = line[at.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            if mac.contains(":") { out[String(line[line.index(after: o)..<c])] = mac }
        }
        return out
    }

    static func ping(_ ip: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/sbin/ping")
                p.arguments = ["-c", "1", "-t", "1", "-q", ip]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: false); return }
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    static func reverseDNS(_ ip: String) -> String {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ip, &addr.sin_addr)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) }
        }
        return r == 0 ? String(cString: host) : ""
    }

    static func scan(cidr: String, concurrency: Int = 64, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [Host] {
        guard let ips = addresses(cidr: cidr) else { return [] }
        var alive: [String] = []
        var done = 0, index = 0
        await withTaskGroup(of: (String, Bool).self) { group in
            func next() {
                guard index < ips.count else { return }
                let ip = ips[index]; index += 1
                group.addTask { (ip, await ping(ip)) }
            }
            for _ in 0..<min(concurrency, ips.count) { next() }
            while let (ip, ok) = await group.next() {
                done += 1
                if ok { alive.append(ip) }
                progress(done, ips.count)
                next()
            }
        }
        let arp = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp"); p.arguments = ["-an"]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
                try? p.run()
                let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                c.resume(returning: String(decoding: d, as: UTF8.self))
            }
        }
        let macs = parseARP(arp)
        return alive.sorted { $0.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes($1.split(separator: ".").compactMap { Int($0) }) }
            .map { Host(ip: $0, name: reverseDNS($0), mac: macs[$0] ?? "") }
    }
}
