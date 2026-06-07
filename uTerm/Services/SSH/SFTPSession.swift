import Foundation
import Citadel
import NIOCore

/// 真实 SFTP 会话：在一个已连上的 `ConnectedClient` 上跑 Citadel SFTP。
actor SFTPSession: SFTPProviding {
    private let connected: ConnectedClient
    private let sftp: SFTPClient

    init(connected: ConnectedClient) async throws {
        self.connected = connected
        self.sftp = try await connected.target.openSFTP()
    }

    func list(path: String) async throws -> [RemoteEntry] {
        let names = try await sftp.listDirectory(atPath: path)
        var entries: [RemoteEntry] = []
        for name in names {
            for component in name.components {
                let filename = component.filename
                if filename == "." || filename == ".." { continue }
                let attributes = component.attributes
                entries.append(
                    RemoteEntry(
                        name: filename,
                        posixPermissions: attributes.permissions,
                        size: attributes.size,
                        modifiedAt: attributes.accessModificationTime?.modificationTime,
                        uid: attributes.uidgid?.userId,
                        gid: attributes.uidgid?.groupId
                    )
                )
            }
        }
        return entries
    }

    func realPath(_ path: String) async throws -> String {
        try await sftp.getRealPath(atPath: path)
    }

    func download(remotePath: String) async throws -> Data {
        try await download(remotePath: remotePath, onProgress: nil)
    }

    func upload(data: Data, toRemotePath: String) async throws {
        try await upload(data: data, toRemotePath: toRemotePath, onProgress: nil)
    }

    func write(_ path: String, data: Data) async throws {
        let file = try await sftp.openFile(
            filePath: path,
            flags: [.write, .create, .truncate]
        )
        do {
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            try await file.write(buffer, at: 0)
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func stat(_ path: String) async throws -> RemoteStat {
        let attrs = try await sftp.getAttributes(at: path)
        let size = Int64(attrs.size ?? 0)
        let mtime = attrs.accessModificationTime?.modificationTime ?? Date()
        return RemoteStat(size: size, mtime: mtime)
    }

    /// 一次性命令 exec —— 委托给 `ConnectedClient.exec`（在 Sendable 包装上调用，
    /// 不把非 Sendable 的 SSHClient 送出 actor）。复用目标 SSH 连接的 exec channel
    /// （与 SFTP 子系统多路复用，不干扰终端 PTY）。
    func exec(_ command: String) async throws -> String {
        try await connected.exec(command)
    }

    // MARK: 目录 / 改名 / 删除

    func rename(_ path: String, to newPath: String) async throws {
        try await sftp.rename(at: path, to: newPath)
    }
    func removeFile(_ path: String) async throws {
        try await sftp.remove(at: path)
    }
    func removeDirectory(_ path: String) async throws {
        try await sftp.rmdir(at: path)
    }
    func createDirectory(_ path: String) async throws {
        try await sftp.createDirectory(atPath: path)
    }

    func setPermissions(path: String, mode: UInt32) async throws {
        // SFTP setstat：只带权限位（`& 0o777`），保留文件类型位不动。
        var attrs = SFTPFileAttributes()
        attrs.permissions = mode & 0o777
        try await sftp.setAttributes(at: path, to: attrs)
    }

    // MARK: 带进度传输

    func upload(data: Data, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let total = Int64(data.count)
        let file = try await sftp.openFile(
            filePath: toRemotePath, flags: [.write, .create, .truncate])
        do {
            let chunk = 32 * 1024
            var offset = 0
            var progressEmitter = TransferProgressEmitter(totalBytes: total)
            func emitProgress(_ bytesDone: Int64) {
                if progressEmitter.shouldEmit(bytesDone: bytesDone) {
                    onProgress?(TransferProgress(bytesDone: bytesDone, bytesTotal: total))
                }
            }
            emitProgress(0)
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + chunk, data.count)
                var buffer = ByteBuffer()
                buffer.writeBytes(data[offset..<end])
                try await file.write(buffer, at: UInt64(offset))
                offset = end
                emitProgress(Int64(offset))
            }
            emitProgress(total)
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func download(remotePath: String,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        let attrs = try await sftp.getAttributes(at: remotePath)
        let total = Int64(attrs.size ?? 0)
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        do {
            var data = Data()
            let chunk: UInt32 = 32 * 1024
            var offset: UInt64 = 0
            var progressEmitter = TransferProgressEmitter(totalBytes: total)
            func emitProgress(_ bytesDone: Int64) {
                if progressEmitter.shouldEmit(bytesDone: bytesDone) {
                    onProgress?(TransferProgress(bytesDone: bytesDone, bytesTotal: total))
                }
            }
            emitProgress(0)
            while true {
                try Task.checkCancellation()
                let buf = try await file.read(from: offset, length: chunk)
                let n = buf.readableBytes
                if n == 0 { break }
                data.append(contentsOf: buf.readableBytesView)
                offset += UInt64(n)
                emitProgress(Int64(offset))
            }
            emitProgress(Int64(data.count))
            try await file.close()
            return data
        } catch {
            try? await file.close()
            throw error
        }
    }

    func close() async {
        try? await sftp.close()
        await connected.close()
    }
}
