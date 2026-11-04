import Foundation
import Virtualization
import CryptoKit

/// "Mini Linux" interno: Alpine Linux arrancado con Virtualization.framework y consola serie integrada.
@MainActor
final class MiniLinuxVM: NSObject, VZVirtualMachineDelegate {
    static let alpineVersion = "3.24.3"
    static var isoName: String { "alpine-virt-\(alpineVersion)-\(Host.current().isARM ? "aarch64" : "x86_64").iso" }
    static var isoURL: URL { URL(string: "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/\(Host.current().isARM ? "aarch64" : "x86_64")/\(isoName)")! }

    /// SHA-256 oficiales de Alpine (https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/<arch>/<iso>.sha256).
    static let isoSHA256 = Host.current().isARM
        ? "e34603080e942e9ebc670689eee77dd7a6551c823a6ff5a299e308ded268098f"
        : "cdc1bc0efc64d8d611bf3733f54868172a545888dfd726f518bf279bcb0ff1af"

    /// Hash por bloques para no cargar toda la imagen en memoria.
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    struct Assets { var kernel: URL; var initrd: URL; var iso: URL }

    enum VMError: LocalizedError {
        case unsupported, download(String), configuration(String), boot(String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Este Mac no admite máquinas virtuales (Virtualization.framework)."
            case .download(let m): return "No se pudo preparar la imagen de Alpine: \(m)"
            case .configuration(let m): return "Configuración de la VM no válida: \(m)"
            case .boot(let m): return "La VM no arrancó: \(m)"
            }
        }
    }

    private(set) var vm: VZVirtualMachine?
    private let toGuest = Pipe()
    private let fromGuest = Pipe()
    var onOutput: (([UInt8]) -> Void)?
    var onStopped: ((String?) -> Void)?
    var sharedFolder: URL?
    var persistFolder: URL?
    var memoryMB = 1024
    var cpus = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

    static var supported: Bool { VZVirtualMachine.isSupported }

    // MARK: imágenes

    /// Busca la ISO en el paquete de la app (modo "todo incluido") o en la caché; si no está, la descarga una sola vez.
    static func prepareAssets(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Assets {
        let dir = Paths.vmDir
        let kernel = dir.appendingPathComponent("vmlinuz-virt")
        let initrd = dir.appendingPathComponent("initramfs-virt")
        var iso = dir.appendingPathComponent(isoName)
        if let bundled = Bundle.main.url(forResource: "alpine-virt", withExtension: "iso", subdirectory: "minilinux") { iso = bundled }
        let fm = FileManager.default
        if !fm.fileExists(atPath: iso.path) {
            progress("Descargando Alpine Linux (~90 MB, solo la primera vez)…")
            let (tmp, resp) = try await URLSession.shared.download(from: isoURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw VMError.download("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
            guard try Self.sha256(of: tmp) == Self.isoSHA256 else {
                try? fm.removeItem(at: tmp)
                throw VMError.download("la imagen descargada no coincide con el SHA-256 oficial de Alpine (no se usará)")
            }
            try? fm.removeItem(at: iso)
            try fm.moveItem(at: tmp, to: iso)
        } else if iso.deletingLastPathComponent() == dir, try Self.sha256(of: iso) != Self.isoSHA256 {
            // la copia en caché fue modificada o está dañada: se descarta y se vuelve a descargar
            try? fm.removeItem(at: iso); try? fm.removeItem(at: kernel); try? fm.removeItem(at: initrd)
            return try await prepareAssets(progress: progress)
        }
        if !fm.fileExists(atPath: kernel.path) || !fm.fileExists(atPath: initrd.path) {
            progress("Extrayendo kernel e initramfs…")
            for (name, dest) in [("boot/vmlinuz-virt", kernel), ("boot/initramfs-virt", initrd)] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
                p.arguments = ["-xOf", iso.path, name]
                fm.createFile(atPath: dest.path, contents: nil)
                p.standardOutput = try FileHandle(forWritingTo: dest)
                p.standardError = Pipe()
                try p.run(); p.waitUntilExit()
                if p.terminationStatus != 0 { throw VMError.download("no se pudo extraer \(name)") }
            }
        }
        try decompressZBootIfNeeded(kernel)
        return Assets(kernel: kernel, initrd: initrd, iso: iso)
    }

    /// Los kernels arm64 de Alpine vienen como "EFI zboot" (cabecera `zimg` + payload gzip); Virtualization.framework
    /// necesita el `Image` sin comprimir. Si el fichero ya es un Image, no hace nada.
    static func decompressZBootIfNeeded(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 0x30, data[4] == 0x7A, data[5] == 0x69, data[6] == 0x6D, data[7] == 0x67 else { return }   // "zimg"
        func le32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
        let off = le32(8), size = le32(12)
        guard off > 0, size > 0, off + size <= data.count else { throw VMError.download("kernel zboot con cabecera inválida") }
        let gz = url.appendingPathExtension("gz")
        try data.subdata(in: off..<(off + size)).write(to: gz)
        let out = url.appendingPathExtension("raw")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-dc", gz.path]
        p.standardOutput = try FileHandle(forWritingTo: out)
        p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        try? FileManager.default.removeItem(at: gz)
        guard p.terminationStatus == 0 else { throw VMError.download("no se pudo descomprimir el kernel") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: out, to: url)
    }

    // MARK: configuración y arranque

    func configuration(assets: Assets) throws -> VZVirtualMachineConfiguration {
        let cfg = VZVirtualMachineConfiguration()
        cfg.cpuCount = max(cfg.cpuCount, min(max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, cpus), VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        cfg.memorySize = UInt64(memoryMB) * 1024 * 1024

        let boot = VZLinuxBootLoader(kernelURL: assets.kernel)
        boot.initialRamdiskURL = assets.initrd
        boot.commandLine = "console=hvc0 modules=loop,squashfs,virtio_blk,virtio_pci,virtio_net,iso9660 quiet"
        cfg.bootLoader = boot
        cfg.platform = VZGenericPlatformConfiguration()

        let disk = try VZDiskImageStorageDeviceAttachment(url: assets.iso, readOnly: true)
        cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: toGuest.fileHandleForReading, fileHandleForWriting: fromGuest.fileHandleForWriting)
        cfg.serialPorts = [serial]

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        cfg.networkDevices = [net]
        cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        cfg.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        var shares: [VZVirtioFileSystemDeviceConfiguration] = []
        for (tag, dir) in [("mac", sharedFolder), ("persist", persistFolder)] {
            guard let dir else { continue }
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: dir, readOnly: false))
            shares.append(fs)
        }
        cfg.directorySharingDevices = shares
        do { try cfg.validate() } catch { throw VMError.configuration(error.localizedDescription) }
        return cfg
    }

    func start(assets: Assets) async throws {
        guard Self.supported else { throw VMError.unsupported }
        let cfg = try configuration(assets: assets)
        let machine = VZVirtualMachine(configuration: cfg)
        machine.delegate = self
        vm = machine
        fromGuest.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let bytes = [UInt8](d)
            Task { @MainActor in self?.onOutput?(bytes) }
        }
        do { try await machine.start() } catch { throw VMError.boot(error.localizedDescription) }
    }

    func send(_ bytes: [UInt8]) {
        try? toGuest.fileHandleForWriting.write(contentsOf: Data(bytes))
    }

    /// Apagado ordenado (señal de apagado al guest) y, si no responde, parada forzada.
    func stop(force: Bool = false) {
        guard let vm else { return }
        if !force, vm.canRequestStop { try? vm.requestStop() }
        else if vm.canStop { vm.stop { _ in } }
        fromGuest.fileHandleForReading.readabilityHandler = nil
    }

    var isRunning: Bool { vm?.state == .running }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.onStopped?(nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in self.onStopped?(error.localizedDescription) }
    }
}

extension Host {
    var isARM: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
