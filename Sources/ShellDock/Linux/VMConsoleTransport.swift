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
        vm.onOutput = { [weak self] bytes in self?.guestOutput(bytes) }
        vm.onStopped = { [weak self] err in
            guard let self, !self.closed else { return }
            self.onClose?(err)
        }
        say("Mini Linux (Alpine \(MiniLinuxVM.alpineVersion)) — preparando…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let assets = try await MiniLinuxVM.prepareAssets { msg in Task { @MainActor in self.say(msg) } }
                self.say("Arrancando la máquina virtual (\(self.vm.cpus) CPU, \(self.vm.memoryMB) MB)…")
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
            // configuración inicial silenciosa; el último comando limpia la pantalla
            // OJO: en sh "&;" es un error de sintaxis, por eso la tarea en segundo plano termina en "& " y no en "&;"
            let net = "{ ip link set eth0 up; udhcpc -i eth0 -q -n; } >/dev/null 2>&1 & "
            let setup = "stty -echo; export TERM=xterm-256color LANG=C.UTF-8; stty cols \(cols) rows \(rows); hostname shelldock-linux; "
                + net
                + "modprobe virtiofs 2>/dev/null; mkdir -p /mnt/mac; mount -t virtiofs mac /mnt/mac 2>/dev/null; "
                + "alias ll='ls -la'; PS1='\\[\\e[1;32m\\]\\u@shelldock-linux\\[\\e[0m\\]:\\[\\e[1;34m\\]\\w\\[\\e[0m\\]# '; "
                + "stty echo; clear; echo \"Alpine Linux $(cat /etc/alpine-release) · $(uname -m) · carpeta del Mac en /mnt/mac · «apk add <paquete>» instala software\""
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
        vm.send(Array("poweroff\r".utf8))
        let machine = vm
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if machine.isRunning { machine.stop(force: true) } }
    }
}
