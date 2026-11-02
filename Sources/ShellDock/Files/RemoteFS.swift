import Foundation

/// Operaciones comunes de un sistema de archivos remoto (SFTP, FTP/FTPS).
protocol RemoteFS: AnyObject, Sendable {
    func realpath(_ path: String) async throws -> String
    func stat(_ path: String, followLinks: Bool) async throws -> RemoteFile
    func list(_ dir: String) async throws -> [RemoteFile]
    func mkdir(_ path: String, mode: UInt32) async throws
    func rename(_ from: String, to: String) async throws
    func chmod(_ path: String, mode: UInt32) async throws
    func removeRecursive(_ file: RemoteFile) async throws
    func download(remote: String, to local: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func upload(local: URL, to remote: String, mode: UInt32, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func close()
}

extension SFTPClient: RemoteFS {}
