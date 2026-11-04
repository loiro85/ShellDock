import Foundation

/// Conecta una pestaña de terminal con la consola de la VM Alpine: prepara las imágenes, arranca, inicia sesión
/// automáticamente, levanta la red, monta la carpeta compartida con el Mac y ajusta el tamaño del terminal.
@MainActor
final class VMConsoleTransport: ByteTransport {
    var onOpen: (() -> Void)?
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?

    private let vm = MiniLinuxVM()
    private let session: Session
    private var cols = 80, rows = 24
    private var tail = ""
    private var loggedIn = false
    private var setupSent = false
    private var closed = false

    /// Carpeta del Mac visible dentro de Linux en /mnt/mac.
    static func shareURL(for s: Session) -> URL {
        if !s.sharedFolder.isEmpty { return URL(fileURLWithPath: (s.sharedFolder as NSString).expandingTildeInPath) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("ShellDock-Linux", isDirectory: true)
    }

    init(session: Session) {
        self.session = session
        vm.memoryMB = session.vmMemoryMB > 0 ? session.vmMemoryMB : 1024
        if session.vmCPUs > 0 { vm.cpus = session.vmCPUs }
    }

    private func say(_ s: String) { onData?(Array(("\u{1b}[36m" + s + "\u{1b}[0m\r\n").utf8)) }

    func open() {
        guard MiniLinuxVM.supported else { onClose?(MiniLinuxVM.VMError.unsupported.localizedDescription); return }
        let share = Self.shareURL(for: session)
        try? FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        vm.sharedFolder = share
        if (try? MiniLinuxPersistence.prepare()) != nil { vm.persistFolder = MiniLinuxPersistence.folder }
        vm.onOutput = { [weak self] bytes in self?.guestOutput(bytes) }
        vm.onStopped = { [weak self] err in
            guard let self, !self.closed else { return }
            self.onClose?(err)
        }
        say(tr("Mini Linux (Alpine %@) — preparando…", "\(MiniLinuxVM.alpineVersion)"))
        Task { [weak self] in
            guard let self else { return }
            do {
                let assets = try await MiniLinuxVM.prepareAssets { msg in Task { @MainActor in self.say(msg) } }
                self.say(tr("Arrancando la máquina virtual (%@ CPU, %@ MB)…", "\(self.vm.cpus)", "\(self.vm.memoryMB)"))
                try await self.vm.start(assets: assets)
                self.onOpen?()
            } catch {
                self.onClose?(error.localizedDescription)
            }
        }
    }

    private func guestOutput(_ bytes: [UInt8]) {
        onData?(bytes)
        tail = String((tail + String(decoding: bytes, as: UTF8.self)).suffix(200))
        if !loggedIn, tail.contains("login:") {
            loggedIn = true
            vm.send(Array("root\r".utf8))
        } else if loggedIn, !setupSent, tail.hasSuffix("# ") || tail.contains("# \u{1b}[6n") || tail.hasSuffix("#") {
            setupSent = true
            let setup = MiniLinuxPersistence.setupLine(cols: cols, rows: rows)
            vm.send(Array((setup + "\r").utf8))
        }
    }

    func send(_ bytes: [UInt8]) { vm.send(bytes) }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        // la consola serie no propaga el tamaño: solo se envía si la shell está esperando una orden
        if setupSent, tail.hasSuffix("# ") { vm.send(Array("stty cols \(cols) rows \(rows)\r".utf8)) }
    }

    func close() {
        closed = true
        vm.send([0x03])
        vm.send(Array("shelldock-save; poweroff\r".utf8))      // guarda el estado antes de apagar
        let machine = vm
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if machine.isRunning { machine.stop(force: true) } }
    }
}
