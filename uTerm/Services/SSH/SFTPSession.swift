import Foundation
import Citadel
import NIOCore

/// 真实 SFTP 会话：在一个已连上的 `ConnectedClient` 上跑 Citadel SFTP。
actor SFTPSession: SFTPProviding {
    private let connected: ConnectedClient
    private let sftp: SFTPClient

    init(connected: ConnectedClient) async throws {
        self.connected = connected
        // openSFTP 失败时，已建立的 SSH 传输（target + 可选 bastion）没人持有、
        // 不会被释放（actor 还没初始化完成、没有 deinit，调用方也拿不到实例去关）。
        // 故失败时先关闭 connected（关 target，再关 bastion），再把错误抛出去。
        do {
            self.sftp = try await connected.target.openSFTP()
        } catch {
            await connected.close()
            throw error
        }
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

    /// 新建空文件：`.create | .forceCreate`（SSH_FXF_CREAT | SSH_FXF_EXCL）——
    /// EXCL 让服务器在路径已存在时直接拒绝，绝不截断既有文件。开成功即关闭，
    /// 留下一个 0 字节文件。
    func createFile(_ path: String) async throws {
        let file = try await sftp.openFile(
            filePath: path,
            flags: [.write, .create, .forceCreate]
        )
        try await file.close()
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

    // MARK: - 存活探测

    /// 主动探测底层 SSH 传输是否存活（看门狗在系统唤醒 / 网络恢复后调用）。
    ///
    /// 用 SFTP 协议自身的 REALPATH（"."）当探测包 —— 走既有 SFTP channel、
    /// 不依赖 exec（SFTP-only 受限账户也安全）、对端必须应答：
    /// - 任何应答（含 SFTP 状态错误）都证明传输活着；
    /// - 超时 / 传输层错误 → 强制关闭底层连接（本地操作、立即完成），让
    ///   后续操作立刻拿到「通道已关」错误而非无限挂死，由
    ///   `FileBrowserModel.refresh` 的自动重连路径接管。
    func verifyConnectionAlive() async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await self.probeRoundTrip() }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil   // nil = 超时
            }
            let first = await group.next() ?? nil
            if first != true {
                // 判死：关掉底层通道。这同时解除可能挂死的探测子任务
                // （REALPATH 拿到「通道已关」错误后返回），TaskGroup 才能收尾。
                await connected.close()
            }
            group.cancelAll()
            return first == true
        }
    }

    /// 一次探测往返。应用层错误（SFTP 状态码等）= 对端在应答 = 活；
    /// 只有传输层错误才判死。
    private func probeRoundTrip() async -> Bool {
        do {
            _ = try await sftp.getRealPath(atPath: ".")
            return true
        } catch {
            return !SSHTransportFailure.isTransportFailure(error)
        }
    }
}
