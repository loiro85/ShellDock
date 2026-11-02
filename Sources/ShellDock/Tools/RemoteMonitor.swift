import Foundation

/// Estado resumido de un servidor remoto (barra de monitorización bajo el terminal SSH).
struct RemoteStats: Equatable {
    var load: String = ""
    var memTotalMB = 0, memUsedMB = 0
    var diskPercent = ""
    var uptime = ""
    var cpus = 0

    var memPercent: Int { memTotalMB > 0 ? memUsedMB * 100 / memTotalMB : 0 }

    static func parse(_ text: String) -> RemoteStats {
        var r = RemoteStats()
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "L": r.load = val
            case "M": let p = val.split(separator: " ").compactMap { Int($0) }; if p.count == 2 { r.memTotalMB = p[0]; r.memUsedMB = p[1] }
            case "D": r.diskPercent = val.split(separator: " ").last.map(String.init) ?? ""
            case "U": r.uptime = val
            case "N": r.cpus = Int(val) ?? 0
            default: break
            }
        }
        return r
    }

    static let script = """
    echo L=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime | sed 's/.*load averages*: //')
    echo M=$(free -m 2>/dev/null | awk '/^Mem:/{print $2" "$3}')
    echo D=$(df -P / | awk 'NR==2{print $2" "$3" "$5}')
    echo U=$(uptime -p 2>/dev/null || uptime | sed 's/^.*up //; s/, *[0-9]* user.*//')
    echo N=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)
    exit
    """
}

/// Consulta periódica por la conexión maestra ya abierta de la pestaña SSH.
@MainActor
final class RemoteMonitor: ObservableObject {
    @Published var stats: RemoteStats?
    private var task: Task<Void, Never>?

    func start(session: Session, hostKeyPolicy: String, interval: TimeInterval = 5) {
        stop()
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                if SSHLauncher.masterIsAlive(session, hostKeyPolicy: hostKeyPolicy), let s = Self.fetch(session, hostKeyPolicy: hostKeyPolicy) {
                    await MainActor.run { self?.stats = s }
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    nonisolated static func fetch(_ s: Session, hostKeyPolicy: String) -> RemoteStats? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHLauncher.sshPath)
        p.arguments = SSHLauncher.commonOptions(s, hostKeyPolicy: hostKeyPolicy, master: false)
            + SSHLauncher.targetArguments(s) + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-T", s.host, "sh"]
        let input = Pipe(), out = Pipe()
        p.standardInput = input; p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(RemoteStats.script.utf8))
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return RemoteStats.parse(String(decoding: data, as: UTF8.self))
    }
}

import SwiftUI

struct MonitorBar: View {
    @StateObject private var monitor = RemoteMonitor()
    let session: Session
    let hostKeyPolicy: String

    var body: some View {
        HStack(spacing: 16) {
            if let s = monitor.stats {
                item("cpu", "\(s.load)" + (s.cpus > 0 ? "  (\(s.cpus) CPU)" : ""))
                if s.memTotalMB > 0 { item("memorychip", "\(s.memUsedMB)/\(s.memTotalMB) MB (\(s.memPercent)%)", warn: s.memPercent > 90) }
                if !s.diskPercent.isEmpty { item("internaldrive", "/ \(s.diskPercent)", warn: (Int(s.diskPercent.dropLast()) ?? 0) > 90) }
                if !s.uptime.isEmpty { item("clock", s.uptime) }
            } else {
                Text("Monitor remoto: esperando datos…").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10).frame(height: 22).background(.bar)
        .onAppear { monitor.start(session: session, hostKeyPolicy: hostKeyPolicy) }
        .onDisappear { monitor.stop() }
    }

    func item(_ icon: String, _ text: String, warn: Bool = false) -> some View {
        HStack(spacing: 4) { Image(systemName: icon); Text(text) }.foregroundStyle(warn ? Color.red : Color.secondary)
    }
}
