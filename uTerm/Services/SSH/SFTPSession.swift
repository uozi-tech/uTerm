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
        try await download(remotePath: remotePath, onProgress: nil, maximumBytes: nil)
    }

    func download(remotePath: String, maximumBytes: Int) async throws -> Data {
        try await download(remotePath: remotePath, onProgress: nil,
                           maximumBytes: max(0, maximumBytes))
    }

    func upload(data: Data, toRemotePath: String) async throws {
        try await upload(data: data, toRemotePath: toRemotePath, onProgress: nil)
    }

    func write(_ path: String, data: Data) async throws {
        try await writeRange(path, offset: 0, data: data, mode: .overwrite)
    }

    // MARK: - 区间读写（分片 / 断点续传的基础原语）

    /// 本地分段大小：每段先攒到内存，再交给流水线切成 32 000 B 并发发出去。
    /// 4 MiB 让内存占用有界，同时远大于「在途窗口」（64 × 32 000 ≈ 2 MiB），
    /// 保证段内一直有活干。
    static let segmentBytes = 4 * 1_048_576

    func writeRange(_ path: String, offset: UInt64, data: Data,
                    mode: SFTPWriteMode) async throws {
        let flags: SFTPOpenFileFlags
        switch mode {
        // SSH_FXF_EXCL：路径已存在时服务端直接拒绝，绝不截断既有文件。
        case .create: flags = [.write, .create, .forceCreate]
        case .overwrite: flags = [.write, .create, .truncate]
        // 不带 TRUNC / APPEND —— 分片并行写同一文件靠的就是这一档。
        case .write: flags = [.write, .create]
        }
        let file = try await sftp.openFile(filePath: path, flags: flags)
        do {
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            try await SFTPPipeline.write(CitadelPipelineFile(file), data: buffer, at: offset)
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let file = try await sftp.openFile(filePath: path, flags: .read)
        do {
            let buffer = try await SFTPPipeline.read(
                CitadelPipelineFile(file), offset: offset, length: length)
            try await file.close()
            return Data(buffer.readableBytesView)
        } catch {
            try? await file.close()
            throw error
        }
    }

    func stat(_ path: String) async throws -> RemoteStat {
        let attrs = try await sftp.getAttributes(at: path)
        let size = Self.clampedSize(attrs.size)
        let mtime = attrs.accessModificationTime?.modificationTime ?? Date()
        return RemoteStat(size: size, mtime: mtime, permissions: attrs.permissions)
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
            let pipelined = CitadelPipelineFile(file)
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
                let end = min(offset + Self.segmentBytes, data.count)
                var buffer = ByteBuffer()
                buffer.writeBytes(data[(data.startIndex + offset)..<(data.startIndex + end)])
                try await SFTPPipeline.write(pipelined, data: buffer, at: UInt64(offset))
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

    func upload(localURL: URL, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let total = Int64(max(0, values.fileSize ?? 0))
        let localFile = try FileHandle(forReadingFrom: localURL)
        do {
            let remoteFile = try await sftp.openFile(
                filePath: toRemotePath, flags: [.write, .create, .truncate])
            do {
                let pipelined = CitadelPipelineFile(remoteFile)
                var offset: UInt64 = 0
                var progressEmitter = TransferProgressEmitter(totalBytes: total)
                func emitProgress(_ bytesDone: Int64) {
                    if progressEmitter.shouldEmit(bytesDone: bytesDone) {
                        onProgress?(TransferProgress(bytesDone: bytesDone, bytesTotal: total))
                    }
                }
                emitProgress(0)
                // 一次读一段本地文件（内存有界），整段交给流水线并发写出去。
                while let data = try localFile.read(upToCount: Self.segmentBytes),
                      !data.isEmpty {
                    try Task.checkCancellation()
                    var buffer = ByteBuffer()
                    buffer.writeBytes(data)
                    try await SFTPPipeline.write(pipelined, data: buffer, at: offset)
                    offset += UInt64(data.count)
                    emitProgress(Int64(clamping: offset))
                }
                emitProgress(Int64(clamping: offset))
                try localFile.close()
                try await remoteFile.close()
            } catch {
                try? await remoteFile.close()
                throw error
            }
        } catch {
            try? localFile.close()
            throw error
        }
    }

    func download(remotePath: String,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        try await download(remotePath: remotePath, onProgress: onProgress,
                           maximumBytes: nil)
    }

    func download(remotePath: String, toLocalURL localURL: URL,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let attrs = try await sftp.getAttributes(at: remotePath)
        let total = Self.clampedSize(attrs.size)
        let remoteFile = try await sftp.openFile(filePath: remotePath, flags: .read)
        let temporaryURL = Self.temporaryDownloadURL(for: localURL)
        let fileManager = FileManager.default
        do {
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let localFile = try FileHandle(forWritingTo: temporaryURL)
            do {
                let pipelined = CitadelPipelineFile(remoteFile)
                var offset: UInt64 = 0
                var progressEmitter = TransferProgressEmitter(totalBytes: total)
                func emitProgress(_ bytesDone: Int64) {
                    if progressEmitter.shouldEmit(bytesDone: bytesDone) {
                        onProgress?(TransferProgress(bytesDone: bytesDone, bytesTotal: total))
                    }
                }
                emitProgress(0)
                // 一段 4 MiB，段内 32 000 B 并发读；读不满即 EOF。
                // 不拿 stat 的 size 当终点 —— 文件在传输期间变长时也要读完。
                while true {
                    try Task.checkCancellation()
                    let want = Self.segmentBytes
                    let buffer = try await SFTPPipeline.read(
                        pipelined, offset: offset, length: want)
                    let count = buffer.readableBytes
                    if count > 0 {
                        try localFile.write(contentsOf: Data(buffer.readableBytesView))
                        offset += UInt64(count)
                        emitProgress(Int64(clamping: offset))
                    }
                    if count < want { break }
                }
                try localFile.synchronize()
                try localFile.close()
                try await remoteFile.close()
                try Self.installDownloadedFile(at: temporaryURL, replacing: localURL)
                emitProgress(Int64(clamping: offset))
            } catch {
                try? localFile.close()
                throw error
            }
        } catch {
            try? await remoteFile.close()
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func temporaryDownloadURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).uterm-\(UUID().uuidString).part",
            isDirectory: false)
    }

    private static func installDownloadedFile(at temporaryURL: URL,
                                              replacing destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    /// 真正的流式下载内核。`maximumBytes` 非 nil 时同时在 stat 后与每个 chunk
    /// append 前检查，既挡已知大文件，也挡下载期间被替换/错误上报 size 的对象。
    private func download(
        remotePath: String,
        onProgress: (@Sendable (TransferProgress) -> Void)?,
        maximumBytes: Int?
    ) async throws -> Data {
        let attrs = try await sftp.getAttributes(at: remotePath)
        let total = Self.clampedSize(attrs.size)
        if let maximumBytes, total > Int64(maximumBytes) {
            throw SFTPDownloadLimitExceeded(observedBytes: total,
                                            maximumBytes: maximumBytes)
        }
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        do {
            var data = Data()
            let pipelined = CitadelPipelineFile(file)
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
                // 有上限时只多要 1 字节：读满即证明超限（而不是刚好读到头），
                // 内存也不会为了判超限先撑到一整段。
                let want: Int
                if let maximumBytes {
                    want = min(Self.segmentBytes, max(1, maximumBytes - data.count + 1))
                } else {
                    want = Self.segmentBytes
                }
                let buf = try await SFTPPipeline.read(
                    pipelined, offset: offset, length: want)
                let n = buf.readableBytes
                if n > 0 {
                    if let maximumBytes, data.count > maximumBytes - n {
                        throw SFTPDownloadLimitExceeded(
                            observedBytes: Int64(data.count) + Int64(n),
                            maximumBytes: maximumBytes)
                    }
                    data.append(contentsOf: buf.readableBytesView)
                    offset += UInt64(n)
                    emitProgress(Int64(offset))
                }
                // 短读 = EOF（流水线读只在到头时给不满）。
                if n < want { break }
            }
            emitProgress(Int64(data.count))
            try await file.close()
            return data
        } catch {
            try? await file.close()
            throw error
        }
    }

    /// SFTP size 是 UInt64；恶意/损坏服务端可回报大于 Int64.max 的值。直接
    /// `Int64(value)` 会 trap，把网络输入变成进程级 DoS，因此统一饱和转换。
    nonisolated static func clampedSize(_ size: UInt64?) -> Int64 {
        guard let size else { return 0 }
        return size > UInt64(Int64.max) ? Int64.max : Int64(size)
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
