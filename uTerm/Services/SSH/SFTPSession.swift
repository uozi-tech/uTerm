import Foundation
import NIOCore
import USSHKit

/// `writeRange` 的失败发生在**哪一阶段**。
///
/// 为什么要分：`create` 档用 SSH_FXF_EXCL 打开，撞上已存在的路径时 SFTP v3 只回
/// `SSH_FX_FAILURE` + 依实现而定的文案，所以 handler 落到兜底码时会再 `stat` 一次
/// 确认「是不是已存在」。但 EXCL **打开成功之后**的写失败（磁盘满、配额、连接断）
/// 此时文件已经被建出来了，那次兜底 `stat` 必然成功 —— 「磁盘满」就被误报成
/// `file_exists`，用户照着提示加 `--force` 重传，然后再次失败。
///
/// 于是只给**打开阶段**的失败包这一层；写阶段的错误原样上抛（`ControlFilePayloadBuilder`
/// 还要认服务端状态码），handler 见不到 `.open` 就不做那次 stat 兜底。
nonisolated struct SFTPWriteStageError: Error, Sendable {
    nonisolated enum Stage: Sendable, Equatable {
        /// 打开文件（含 EXCL 冲突、权限、路径不存在）。
        case open
    }

    let stage: Stage
    let underlying: any Error

    /// 剥掉阶段外壳拿原错误；不是本类型就原样返回。错误归类（`errorCode(for:)` /
    /// `errorDetail(for:)`）一律先过这一道，免得包装把服务端状态码藏起来。
    static func unwrap(_ error: any Error) -> any Error {
        (error as? SFTPWriteStageError)?.underlying ?? error
    }

    /// 这个错误是不是「打开阶段」失败。
    static func isOpenFailure(_ error: any Error) -> Bool {
        (error as? SFTPWriteStageError)?.stage == .open
    }
}

/// 真实 SFTP 会话：在一个已连上的 `ConnectedClient` 上跑 USSHCore 的 SFTP 客户端。
actor SFTPSession: SFTPProviding {
    private let connected: ConnectedClient
    private let sftp: SFTPClient
    /// 上传（`upload`）按节奏传（`SFTPUploadPacer`）。连接与同主机的终端共用时必须开：一传大文件，终端的按键要排在
    /// 几 MB 上传数据后面才发得出去。命令行的传输走自己的连接、上面没有终端，关掉换满速。
    private let pacesUploads: Bool

    init(connected: ConnectedClient, pacesUploads: Bool = true) async throws {
        self.connected = connected
        self.pacesUploads = pacesUploads
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

    /// 列目录时见过的、名字不是合法 UTF-8 的条目：显示用的路径（非法字节换成 U+FFFD 的 `String`，界面和
    /// `RemoteEntry.name` 拿的就是它）→ 服务器上的原样字节。之后拿这个路径（或它下面的路径）来操作时换回原样字节，
    /// 非 UTF-8 的文件名才能打开、改名、删除，而不是「找不到」或打到别的文件上。见 `sftpPath(_:)`。
    private var rawPaths: [String: SFTPPath] = [:]

    /// 界面 / 调用方给的路径 → 发给服务器的路径。落在某个非 UTF-8 条目上或它下面时换回原样字节；
    /// 其余照 UTF-8 编码（和以前一样）。
    func sftpPath(_ path: String) -> SFTPPath {
        guard !rawPaths.isEmpty else { return SFTPPath(path) }
        if let exact = rawPaths[path] { return exact }
        var best: (display: String, raw: SFTPPath)?
        for (display, raw) in rawPaths where path.hasPrefix(display.hasSuffix("/") ? display : display + "/") {
            if display.utf8.count > (best?.display.utf8.count ?? -1) { best = (display, raw) }
        }
        guard let best else { return SFTPPath(path) }
        var rest = Array(path.utf8.dropFirst(best.display.utf8.count))
        if best.raw.bytes.last == UInt8(ascii: "/"), rest.first == UInt8(ascii: "/") { rest.removeFirst() }
        return SFTPPath(bytes: best.raw.bytes + rest)
    }

    func list(path: String) async throws -> [RemoteEntry] {
        // 不带 "." / ".."（`includingDotEntries` 默认 false）。
        let directory = sftpPath(path)
        let listed = try await sftp.listDirectory(directory)
        for entry in listed where !entry.name.isLosslessUTF8 {
            rawPaths[RemotePath.join(path, entry.filename)] = directory.appending(entry.name)
        }
        return listed.map { entry in
            let attributes = entry.attributes
            return RemoteEntry(
                name: entry.filename,
                posixPermissions: attributes.permissions,
                size: attributes.size,
                modifiedAt: attributes.modificationDate,
                uid: attributes.owner?.userID,
                gid: attributes.owner?.groupID
            )
        }
    }

    func realPath(_ path: String) async throws -> String {
        try await sftp.realPath(sftpPath(path)).string
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

    /// 本地分段大小：每段先攒到内存，再交给流水线按服务器的单请求上限切片并发发出去。
    /// 4 MiB 让内存占用有界，同时不小于通道窗口（2 MiB），保证段内一直有活干。
    static let segmentBytes = 4 * 1_048_576

    func writeRange(_ path: String, offset: UInt64, data: Data,
                    mode: SFTPWriteMode) async throws {
        let flags: SFTPOpenFlags
        switch mode {
        // SSH_FXF_EXCL：路径已存在时服务端直接拒绝，绝不截断既有文件。
        case .create: flags = [.write, .create, .exclusive]
        case .overwrite: flags = [.write, .create, .truncate]
        // 不带 TRUNC / APPEND —— 分片并行写同一文件靠的就是这一档。
        case .write: flags = [.write, .create]
        }
        let file: SFTPFile
        do {
            file = try await sftp.openFile(sftpPath(path), flags: flags)
        } catch {
            // 打开阶段失败：包上阶段标记，handler 才敢做「是不是已存在」的 stat 兜底。
            throw SFTPWriteStageError(stage: .open, underlying: error)
        }
        do {
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            try await SFTPPipeline.write(USSHPipelineFile(file), data: buffer, at: offset)
            try await file.close()
        } catch {
            // 写阶段失败原样上抛（文件已经建出来了，此时的 stat 兜底只会误报 file_exists）。
            try? await file.close()
            throw error
        }
    }

    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let file = try await sftp.openFile(sftpPath(path), flags: .read)
        do {
            let buffer = try await SFTPPipeline.read(
                USSHPipelineFile(file), offset: offset, length: length)
            try await file.close()
            return Data(buffer.readableBytesView)
        } catch {
            try? await file.close()
            throw error
        }
    }

    func openTransferHandle(_ path: String, writeMode: SFTPWriteMode?) async throws -> SFTPTransferHandle {
        let flags: SFTPOpenFlags
        switch writeMode {
        case nil: flags = .read
        // SSH_FXF_EXCL：路径已存在时服务端直接拒绝，绝不截断既有文件。
        case .create: flags = [.write, .create, .exclusive]
        case .overwrite: flags = [.write, .create, .truncate]
        // 不截断：并行写 / 续传都落在这档。
        case .write: flags = [.write, .create]
        }
        let file: SFTPFile
        do {
            file = try await sftp.openFile(sftpPath(path), flags: flags)
        } catch where writeMode != nil {
            throw SFTPWriteStageError(stage: .open, underlying: error)
        }
        let pipelined = USSHPipelineFile(file)
        return SFTPTransferHandle(file: pipelined, close: { await pipelined.close() })
    }

    func stat(_ path: String) async throws -> RemoteStat {
        let attrs = try await sftp.stat(sftpPath(path))
        let size = Self.clampedSize(attrs.size)
        let mtime = attrs.modificationDate ?? Date()
        return RemoteStat(size: size, mtime: mtime, permissions: attrs.permissions)
    }

    /// 一次性命令 exec —— 委托给 `ConnectedClient.exec`。复用目标 SSH 连接开 exec channel
    /// （与 SFTP 子系统多路复用，不干扰终端 PTY）。
    func exec(_ command: String) async throws -> String {
        try await connected.exec(command)
    }

    // MARK: 目录 / 改名 / 删除

    func rename(_ path: String, to newPath: String) async throws {
        // 标准 RENAME（目标已存在时服务器拒绝），与以前一样不覆盖。
        try await sftp.rename(sftpPath(path), to: sftpPath(newPath))
    }
    func removeFile(_ path: String) async throws {
        try await sftp.remove(sftpPath(path))
    }
    func removeDirectory(_ path: String) async throws {
        try await sftp.removeDirectory(sftpPath(path))
    }
    func createDirectory(_ path: String) async throws {
        try await sftp.createDirectory(sftpPath(path))
    }

    /// 新建空文件：`.create | .exclusive`（SSH_FXF_CREAT | SSH_FXF_EXCL）——
    /// EXCL 让服务器在路径已存在时直接拒绝，绝不截断既有文件。开成功即关闭，
    /// 留下一个 0 字节文件。
    func createFile(_ path: String) async throws {
        let file = try await sftp.openFile(sftpPath(path),
            flags: [.write, .create, .exclusive]
        )
        try await file.close()
    }

    func setPermissions(path: String, mode: UInt32) async throws {
        // SFTP setstat：只带权限位（`& 0o777`），保留文件类型位不动。
        var attrs = SFTPFileAttributes()
        attrs.permissions = mode & 0o777
        try await sftp.setAttributes(attrs, at: sftpPath(path))
    }

    // MARK: 带进度传输

    func upload(data: Data, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let total = Int64(data.count)
        let file = try await sftp.openFile(sftpPath(toRemotePath), flags: [.write, .create, .truncate])
        do {
            let pipelined = USSHPipelineFile(file)
            var offset = 0
            var pacer = pacesUploads ? SFTPUploadPacer() : nil
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
                try await SFTPPipeline.write(pipelined, data: buffer, at: UInt64(offset), pacer: &pacer)
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
        // 先确认本地文件读得到，再在远端建文件（读不到就别把远端的同名文件截断了）。
        let total = Int64(max(0, try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        try FileHandle(forReadingFrom: localURL).close()
        let remoteFile = try await sftp.openFile(sftpPath(toRemotePath), flags: [.write, .create, .truncate])
        do {
            var progressEmitter = TransferProgressEmitter(totalBytes: total)
            // 一次读一段本地文件（内存有界），整段交给流水线并发写出去。写完最后一片时报到总数（emitter 必放行）。
            try await SFTPPipeline.write(USSHPipelineFile(remoteFile), contentsOf: localURL,
                                         segmentBytes: Self.segmentBytes, paced: pacesUploads) { written, _ in
                if progressEmitter.shouldEmit(bytesDone: written) {
                    onProgress?(TransferProgress(bytesDone: written, bytesTotal: total))
                }
            }
            try await remoteFile.close()
        } catch {
            try? await remoteFile.close()
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
        let attrs = try await sftp.stat(sftpPath(remotePath))
        let total = Self.clampedSize(attrs.size)
        let remoteFile = try await sftp.openFile(sftpPath(remotePath), flags: .read)
        let temporaryURL = Self.temporaryDownloadURL(for: localURL)
        let fileManager = FileManager.default
        do {
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let localFile = try FileHandle(forWritingTo: temporaryURL)
            do {
                let pipelined = USSHPipelineFile(remoteFile)
                var offset: UInt64 = 0
                var progressEmitter = TransferProgressEmitter(totalBytes: total)
                func emitProgress(_ bytesDone: Int64) {
                    if progressEmitter.shouldEmit(bytesDone: bytesDone) {
                        onProgress?(TransferProgress(bytesDone: bytesDone, bytesTotal: total))
                    }
                }
                emitProgress(0)
                // 按 stat 的 size 精确分段（每段必须读满），再把传输期间长出来的尾巴读完。
                _ = try await readWholeFile(
                    pipelined, declaredSize: total, maximumBytes: nil
                ) { buffer in
                    try localFile.write(contentsOf: Data(buffer.readableBytesView))
                    offset += UInt64(buffer.readableBytes)
                    emitProgress(Int64(clamping: offset))
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
        let attrs = try await sftp.stat(sftpPath(remotePath))
        let total = Self.clampedSize(attrs.size)
        if let maximumBytes, total > Int64(maximumBytes) {
            throw SFTPDownloadLimitExceeded(observedBytes: total,
                                            maximumBytes: maximumBytes)
        }
        let file = try await sftp.openFile(sftpPath(remotePath), flags: .read)
        do {
            var data = Data()
            let pipelined = USSHPipelineFile(file)
            var offset: UInt64 = 0
            var progressEmitter = TransferProgressEmitter(totalBytes: total)
            func emitProgress(_ bytesDone: Int64) {
                if progressEmitter.shouldEmit(bytesDone: bytesDone) {
                    onProgress?(TransferProgress(bytesDone: bytesDone, bytesTotal: total))
                }
            }
            emitProgress(0)
            _ = try await readWholeFile(
                pipelined, declaredSize: total, maximumBytes: maximumBytes
            ) { buffer in
                data.append(contentsOf: buffer.readableBytesView)
                offset += UInt64(buffer.readableBytes)
                emitProgress(Int64(clamping: offset))
            }
            emitProgress(Int64(data.count))
            try await file.close()
            return data
        } catch {
            try? await file.close()
            throw error
        }
    }

    /// 整文件读的**唯一**内核：先按 `declaredSize`（stat 的大小）精确分段读，每段
    /// 必须读满；`declaredSize` 之后再用非严格模式把「stat 之后文件又长大」的尾巴读完。
    ///
    /// 这两句合起来堵的是一个数据完整性事故：以前的判据是「这一段返回的字节数少于
    /// 请求 = EOF，收工」。服务端一次短读 / 空读（网络抖动、并发写、实现偷懒）就能让
    /// 12 MiB 的下载在 116 KiB 处**报成功**。现在长度已知的部分一律
    /// `requireFullLength`，短了就抛 `SFTPShortReadError`，绝不静默收尾。
    ///
    /// `onSegment` 逐段消费（写本地文件 / 追加进内存），保证内存有界。
    /// 返回实际读到的总字节数。
    private func readWholeFile(
        _ file: some SFTPPipelineFile,
        declaredSize: Int64,
        maximumBytes: Int?,
        onSegment: (ByteBuffer) throws -> Void
    ) async throws -> Int64 {
        var offset: UInt64 = 0
        var produced: Int64 = 0
        var remaining = max(0, declaredSize)
        while remaining > 0 {
            try Task.checkCancellation()
            let want = Int(min(Int64(Self.segmentBytes), remaining))
            try Self.checkDownloadLimit(maximumBytes, produced: produced, incoming: want)
            let buffer = try await SFTPPipeline.read(
                file, offset: offset, length: want, requireFullLength: true)
            try onSegment(buffer)
            offset += UInt64(want)
            produced += Int64(want)
            remaining -= Int64(want)
        }
        // stat 之后还在长（日志文件之类）：非严格地续读，读不满才是真的到头。
        // 第一发只探一个请求那么长 —— 绝大多数文件没在长，拿整段 4 MiB 去探
        // 等于每次下载白发几十上百个必然落空的并发 READ。确认在长了再切回整段。
        var want = max(1, file.maximumReadLength)
        while true {
            try Task.checkCancellation()
            let buffer = try await SFTPPipeline.read(file, offset: offset, length: want)
            let count = buffer.readableBytes
            if count > 0 {
                try Self.checkDownloadLimit(maximumBytes, produced: produced, incoming: count)
                try onSegment(buffer)
                offset += UInt64(count)
                produced += Int64(count)
            }
            if count < want { break }
            want = Self.segmentBytes
        }
        return produced
    }

    /// 有界下载的闸：**追加之前**判，绝不先把超限的数据收进内存再说。
    private nonisolated static func checkDownloadLimit(
        _ maximumBytes: Int?,
        produced: Int64,
        incoming: Int
    ) throws {
        guard let maximumBytes else { return }
        let after = produced + Int64(incoming)
        guard after > Int64(maximumBytes) else { return }
        throw SFTPDownloadLimitExceeded(observedBytes: after, maximumBytes: maximumBytes)
    }

    /// SFTP size 是 UInt64；恶意/损坏服务端可回报大于 Int64.max 的值。直接
    /// `Int64(value)` 会 trap，把网络输入变成进程级 DoS，因此统一饱和转换。
    nonisolated static func clampedSize(_ size: UInt64?) -> Int64 {
        guard let size else { return 0 }
        return size > UInt64(Int64.max) ? Int64.max : Int64(size)
    }

    func close() async {
        await sftp.close()
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
                // 共享连接上的终端也会收到断开、各自重连。
                await connected.closeTransport()
            }
            group.cancelAll()
            return first == true
        }
    }

    /// 一次探测往返。应用层错误（SFTP 状态码等）= 对端在应答 = 活；
    /// 只有传输层错误才判死。
    private func probeRoundTrip() async -> Bool {
        do {
            _ = try await sftp.realPath(".")
            return true
        } catch {
            return !SSHTransportFailure.isTransportFailure(error)
        }
    }
}
