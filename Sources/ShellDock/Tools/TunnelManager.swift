import Foundation
import SwiftUI

/// Gestor de túneles SSH independientes de las pestañas: se pueden arrancar y parar sin terminal.
@MainActor
final class TunnelManager: ObservableObject {
    enum State: Equatable {
        case stopped, starting, running
        case failed(String)
        var label: String {
            switch self {
            case .stopped: return "Parado"
            case .starting: return "Iniciando…"
            case .running: return "Activo"
            case .failed(let m): return m
            }
        }
    }

    @Published private(set) var states: [UUID: State] = [:]
    private var procs: [UUID: Process] = [:]

    func state(_ id: UUID) -> State { states[id] ?? .stopped }

    static func arguments(for t: SavedTunnel, session s: Session, hostKeyPolicy: String) -> [String] {
        var a = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=15"]
        a += SSHLauncher.commonOptions(s, hostKeyPolicy: hostKeyPolicy, master: false)
        if !(s.hasStoredPassword || s.hasStoredPassphrase) { a += ["-o", "BatchMode=yes"] }
        a += SSHLauncher.targetArguments(s)
        a += t.tunnel.sshArguments
        a += ShellSplit.split(s.extraArguments)
        a.append(s.host)
        return a
    }

    func start(_ t: SavedTunnel, session s: Session, hostKeyPolicy: String) {
        stop(t.id)
        states[t.id] = .starting
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHLauncher.sshPath)
        p.arguments = Self.arguments(for: t, session: s, hostKeyPolicy: hostKeyPolicy)
        var env: [String: String] = [:]
        for kv in SSHLauncher.environment(for: s) { if let i = kv.firstIndex(of: "=") { env[String(kv[kv.startIndex..<i])] = String(kv[kv.index(after: i)...]) } }
        p.environment = env
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        let id = t.id
        p.terminationHandler = { [weak self] proc in
            let msg = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard let self, self.procs[id] === proc else { return }
                self.procs[id] = nil
                if proc.terminationReason == .exit && proc.terminationStatus != 0 {
                    self.states[id] = .failed(msg.isEmpty ? "ssh terminó con código \(proc.terminationStatus)" : String(msg.split(separator: "\n").last ?? ""))
                } else { self.states[id] = .stopped }
            }
        }
        do { try p.run() } catch { states[id] = .failed(error.localizedDescription); return }
        procs[id] = p
        Task { [weak self] in
            // un túnel sano sigue vivo tras la negociación; ExitOnForwardFailure lo cierra si falla
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self, self.procs[id] === p, p.isRunning, self.states[id] == .starting else { return }
            self.states[id] = .running
        }
    }

    func stop(_ id: UUID) {
        if let p = procs[id] {
            procs[id] = nil
            p.terminate()
        }
        states[id] = .stopped
    }

    func stopAll() { for id in Array(procs.keys) { stop(id) } }
}
