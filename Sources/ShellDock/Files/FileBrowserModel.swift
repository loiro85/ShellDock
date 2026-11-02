import Foundation
import AppKit

struct Transfer: Identifiable {
    enum Direction { case upload, download }
    let id = UUID()
    var name: String
    var direction: Direction
    var done: Int64 = 0
    var total: Int64 = 0
    var finished = false
    var error: String?
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : (finished ? 1 : 0) }
}

@MainActor
final class FileBrowserModel: ObservableObject {
    enum State: Equatable { case waiting, connecting, ready, failed(String) }

    @Published var state: State = .waiting
    @Published var path = "/"
    @Published var entries: [RemoteFile] = []
    @Published var selection = Set<String>()
    @Published var showHidden = false
    @Published var loading = false
    @Published var transfers: [Transfer] = []
    @Published var message: String?
    @Published var editorDoc: EditorDoc?
    /// Editor interno (true) o la app predeterminada del sistema (false); lo fija el panel según los ajustes.
    var useInternalEditor = true

    let session: Session
    private let hostKeyPolicy: String
    private var client: (any RemoteFS)?
    private let direct: Bool
    private var startTask: Task<Void, Never>?
    private var history: [String] = []
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    var terminalSend: ((String) -> Void)?
    static weak var last: FileBrowserModel?        // solo para diagnóstico (--probe)

    /// `direct`: sesiones SFTP/FTP propias (sin pestaña SSH); no hace falta esperar a una conexión maestra.
    init(session: Session, hostKeyPolicy: String, direct: Bool = false) {
        self.direct = direct
        self.session = session
        self.hostKeyPolicy = hostKeyPolicy
        Self.last = self
    }

    deinit { startTask?.cancel() }

    var visibleEntries: [RemoteFile] {
        entries.filter { showHidden || !$0.isHidden }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    // MARK: conexión

    /// Espera a que la sesión SSH tenga su conexión maestra abierta y se conecta por SFTP sobre ella.
    func start() {
        startTask?.cancel()
        state = .waiting
        let s = session, policy = hostKeyPolicy, direct = self.direct
        startTask = Task { [weak self] in
            if direct { await self?.connect(); return }
            // sesiones con credenciales guardadas pueden conectar por su cuenta; el resto espera al login
            let selfAuth = s.hasStoredPassword || s.hasStoredPassphrase || s.auth == .key || s.auth == .agent
            var waited = 0
            while !Task.isCancelled {
                let alive = await Task.detached { SSHLauncher.masterIsAlive(s, hostKeyPolicy: policy) }.value
                if alive || (selfAuth && waited >= 2) { break }
                waited += 1
                if waited > 600 { await MainActor.run { self?.state = .failed("No se detectó la conexión SSH") }; return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func connect() async {
        state = .connecting
        if session.kind == .ftp {
            let c = FTPClient(session: session)
            do {
                try await c.connect()
                client = c
                state = .ready
                await navigate(to: "/", push: false)
            } catch { state = .failed(error.localizedDescription) }
            return
        }
        let c = SFTPClient()
        do {
            try await c.start(executable: SSHLauncher.sshPath,
                              arguments: SSHLauncher.sftpSubsystemArguments(session, hostKeyPolicy: hostKeyPolicy),
                              environment: SSHLauncher.environment(for: session, forceAskpass: direct))
            client = c
            let home = try await c.realpath(".")
            state = .ready
            await navigate(to: home, push: false)
        } catch {
            c.close()
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        startTask?.cancel()
        for t in transferTasks.values { t.cancel() }
        client?.close()
        client = nil
        for w in watchers.values { w.cancel() }
        watchers = [:]
    }

    // MARK: navegación

    func navigate(to p: String, push: Bool = true) async {
        guard let c = client else { return }
        loading = true
        defer { loading = false }
        do {
            let target = try await c.realpath(p)
            let list = try await c.list(target)
            if push, path != target { history.append(path) }
            path = target
            entries = list
            selection = []
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func refresh() { Task { await navigate(to: path, push: false) } }
    func goUp() { Task { await navigate(to: (path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent) } }
    func goBack() { if let p = history.popLast() { Task { await navigate(to: p, push: false) } } }
    func goHome() { Task { await navigate(to: ".") } }

    func open(_ f: RemoteFile) {
        Task {
            guard let c = client else { return }
            var isDir = f.isDirectory
            if f.isSymlink, let st = try? await c.stat(f.path, followLinks: true) { isDir = st.isDirectory }
            if isDir { await navigate(to: f.path) } else if useInternalEditor { editInternal(f) } else { edit(f) }
        }
    }

    // MARK: operaciones

    private func run(_ what: String, _ op: @escaping (any RemoteFS) async throws -> Void) {
        guard let c = client else { return }
        Task {
            do { try await op(c); await navigate(to: path, push: false) }
            catch { message = "\(what): \(error.localizedDescription)" }
        }
    }

    func makeFolder(_ name: String) { run("Crear carpeta") { try await $0.mkdir(self.path + (self.path == "/" ? "" : "/") + name, mode: 0o755) } }

    func rename(_ f: RemoteFile, to name: String) {
        run("Renombrar") { try await $0.rename(f.path, to: (f.path as NSString).deletingLastPathComponent + "/" + name) }
    }

    func delete(_ files: [RemoteFile]) {
        run("Eliminar") { c in for f in files { try await c.removeRecursive(f) } }
    }

    func chmod(_ f: RemoteFile, mode: UInt32) { run("Permisos") { try await $0.chmod(f.path, mode: mode) } }

    func copyPath(_ f: RemoteFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(f.path, forType: .string)
    }

    func cdInTerminal(_ f: RemoteFile?) {
        let target = f.map { $0.isDirectory ? $0.path : ($0.path as NSString).deletingLastPathComponent } ?? path
        terminalSend?("cd \(ShellSplit.quote(target))\r")
    }

    // MARK: transferencias

    private func track(_ t: Transfer, work: @escaping (@escaping @Sendable (Int64, Int64) -> Void) async throws -> Void) {
        transfers.append(t)
        let id = t.id
        let task = Task { [weak self] in
            let report: @Sendable (Int64, Int64) -> Void = { d, tot in
                Task { @MainActor in
                    guard let self, let i = self.transfers.firstIndex(where: { $0.id == id }) else { return }
                    self.transfers[i].done = d
                    self.transfers[i].total = tot
                }
            }
            do {
                try await work(report)
                await MainActor.run {
                    if let i = self?.transfers.firstIndex(where: { $0.id == id }) { self?.transfers[i].finished = true }
                }
            } catch {
                await MainActor.run {
                    if let i = self?.transfers.firstIndex(where: { $0.id == id }) { self?.transfers[i].error = error.localizedDescription; self?.transfers[i].finished = true }
                }
            }
            await MainActor.run { self?.transferTasks[id] = nil }
        }
        transferTasks[id] = task
    }

    func upload(_ urls: [URL]) {
        guard let c = client else { return }
        let dest = path
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                uploadFolder(url, to: dest + (dest == "/" ? "" : "/") + url.lastPathComponent, client: c)
            } else {
                let remote = dest + (dest == "/" ? "" : "/") + url.lastPathComponent
                track(Transfer(name: url.lastPathComponent, direction: .upload)) { report in
                    try await c.upload(local: url, to: remote, mode: 0o644, progress: report)
                    await self.navigate(to: dest, push: false)
                }
            }
        }
    }

    private func uploadFolder(_ dir: URL, to remote: String, client c: any RemoteFS) {
        track(Transfer(name: dir.lastPathComponent + "/", direction: .upload)) { report in
            try? await c.mkdir(remote, mode: 0o755)
            let fm = FileManager.default
            var files: [(URL, String)] = []
            let base = dir.path
            if let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let u as URL in en {
                    let rel = String(u.path.dropFirst(base.count + 1))
                    let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir { try? await c.mkdir(remote + "/" + rel, mode: 0o755) } else { files.append((u, rel)) }
                }
            }
            var done = 0
            for (u, rel) in files {
                try Task.checkCancellation()
                try await c.upload(local: u, to: remote + "/" + rel, mode: 0o644, progress: { _, _ in })
                done += 1
                report(Int64(done), Int64(files.count))
            }
            await self.navigate(to: self.path, push: false)
        }
    }

    func download(_ files: [RemoteFile], to dir: URL) {
        guard let c = client else { return }
        for f in files {
            if f.isDirectory {
                track(Transfer(name: f.name + "/", direction: .download)) { report in
                    try await self.downloadFolder(f.path, to: dir.appendingPathComponent(f.name), client: c, report: report)
                }
            } else {
                track(Transfer(name: f.name, direction: .download)) { report in
                    try await c.download(remote: f.path, to: dir.appendingPathComponent(f.name), progress: report)
                }
            }
        }
    }

    private func downloadFolder(_ remote: String, to local: URL, client c: any RemoteFS, report: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for f in try await c.list(remote) {
            try Task.checkCancellation()
            if f.isDirectory { try await downloadFolder(f.path, to: local.appendingPathComponent(f.name), client: c, report: report) }
            else { try await c.download(remote: f.path, to: local.appendingPathComponent(f.name), progress: { _, _ in }) }
        }
        report(1, 1)
    }

    func chooseDownloadFolder(for files: [RemoteFile]) {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "Descargar aquí"
        if p.runModal() == .OK, let u = p.url { download(files, to: u) }
    }

    func chooseUpload() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.prompt = "Subir"
        if p.runModal() == .OK { upload(p.urls) }
    }

    func cancel(_ t: Transfer) { transferTasks[t.id]?.cancel() }
    func clearFinished() { transfers.removeAll { $0.finished } }

    // MARK: edición remota

    /// Descarga a una carpeta temporal, abre con la app predeterminada y vuelve a subir cada vez que se guarda.
    func edit(_ f: RemoteFile) {
        guard let c = client else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelldock-edit-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(f.name)
        track(Transfer(name: f.name, direction: .download)) { report in
            try await c.download(remote: f.path, to: local, progress: report)
            await MainActor.run {
                NSWorkspace.shared.open(local)
                self.watch(local: local, remote: f.path, client: c)
            }
        }
    }

    /// Descarga el archivo y lo abre en el editor integrado (se guarda con ⌘S).
    func editInternal(_ f: RemoteFile) {
        guard let c = client else { return }
        if f.size > 8 * 1024 * 1024 { message = "\(f.name) pesa más de 8 MB: se abre con la app del sistema"; edit(f); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelldock-edit-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(f.name)
        track(Transfer(name: f.name, direction: .download)) { report in
            try await c.download(remote: f.path, to: local, progress: report)
            guard let data = try? Data(contentsOf: local) else { return }
            await MainActor.run {
                guard let text = String(data: data, encoding: .utf8) else {
                    self.message = "\(f.name) no es texto UTF-8: se abre con la app del sistema"
                    NSWorkspace.shared.open(local); self.watch(local: local, remote: f.path, client: c); return
                }
                self.editorDoc = EditorDoc(name: f.name, remotePath: f.path, local: local, text: text)
            }
        }
    }

    func saveEditor(_ doc: EditorDoc, text: String) {
        guard let c = client else { return }
        do { try text.write(to: doc.local, atomically: true, encoding: .utf8) } catch { message = error.localizedDescription; return }
        track(Transfer(name: doc.name + " (guardado)", direction: .upload)) { report in
            try await c.upload(local: doc.local, to: doc.remotePath, mode: 0o644, progress: report)
        }
    }

    private func watch(local: URL, remote: String, client c: any RemoteFS) {
        let fd = Darwin.open(local.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        var debounce: DispatchWorkItem?
        src.setEventHandler { [weak self] in
            debounce?.cancel()
            let w = DispatchWorkItem {
                guard FileManager.default.fileExists(atPath: local.path) else { return }
                self?.track(Transfer(name: local.lastPathComponent + " (guardado)", direction: .upload)) { report in
                    try await c.upload(local: local, to: remote, mode: 0o644, progress: report)
                }
            }
            debounce = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watchers[remote]?.cancel()
        watchers[remote] = src
    }
}
