import Foundation

/// 主控端把文件夹共享给被控 Mac 时，收到的文件请求交给谁。由 App 接线（只有 Mac 有，手机没有可共享的文件）。
nonisolated struct RemoteFileSharingAccess: Sendable {
    /// 此刻共享给这台 Mac 的范围。nil 或空 = 什么也没共享。每条请求都现问，改了共享立刻生效。
    let scope: @MainActor @Sendable () -> RemoteFileScope?
    /// 打包好的请求进、打包好的应答出，只放行范围里的。不抛错。
    let perform: @Sendable (Data, RemoteFileScope) async -> Data

    init(scope: @escaping @MainActor @Sendable () -> RemoteFileScope?,
         perform: @escaping @Sendable (Data, RemoteFileScope) async -> Data) {
        self.scope = scope
        self.perform = perform
    }
}

/// 分片传输：窗口内并发地读 / 写若干片，哪一片先回来不要紧，各自带着偏移。
///
/// 服务无状态，所以续传就是只传还没传的区间；一片失败会重试，连接断了的那种失败由 `performFile` 里的
/// 建连顶上（它每次都先确保连着）。
nonisolated enum RemoteMacTransfer {
    typealias Perform = @Sendable (RemoteFileRequest, Data) async throws -> (reply: RemoteFileReply, body: Data)

    struct Range: Sendable, Equatable {
        var offset: Int64
        var length: Int64
    }

    static let attempts = 3

    /// 把 `ranges`（nil = 整份）切成片。
    static func pieces(size: Int64, ranges: [Range]?, chunk: Int = RemoteFileLimits.transferChunkBytes) -> [Range] {
        var result: [Range] = []
        for range in ranges ?? [Range(offset: 0, length: size)] {
            var offset = range.offset
            let end = range.offset + range.length
            while offset < end {
                let length = min(Int64(chunk), end - offset)
                result.append(Range(offset: offset, length: length))
                offset += length
            }
        }
        return result
    }

    /// 远端 → 本地。每片读回来就交给 `sink`（并发调用，实现要自己能并发写不同区间，比如 `pwrite`）。
    static func download(path: String, size: Int64, ranges: [Range]? = nil, window: Int = RemoteFileLimits.transferWindow,
                         perform: @escaping Perform, sink: @escaping @Sendable (Int64, Data) throws -> Void,
                         onPiece: (@Sendable (Range) -> Void)? = nil) async throws {
        try await run(pieces(size: size, ranges: ranges), window: window) { piece in
            var request = RemoteFileRequest(op: .read, path: path)
            request.offset = UInt64(piece.offset)
            request.length = Int(piece.length)
            let (_, data) = try await perform(request, Data())
            guard Int64(data.count) == piece.length else {
                throw RemoteFileError(.failed, String(localized: "\(path)：传输途中文件变短了（偏移 \(String(piece.offset)) 处只读到 \(data.count) 字节）"))
            }
            try sink(piece.offset, data)
            onPiece?(piece)
        }
    }

    /// 本地 → 远端。`source` 给出某个区间的字节（并发调用）。远端文件要已经存在（调用方先建好、截断好）。
    static func upload(path: String, size: Int64, ranges: [Range]? = nil, window: Int = RemoteFileLimits.transferWindow,
                       perform: @escaping Perform, source: @escaping @Sendable (Int64, Int) throws -> Data,
                       onPiece: (@Sendable (Range) -> Void)? = nil) async throws {
        try await run(pieces(size: size, ranges: ranges), window: window) { piece in
            let data = try source(piece.offset, Int(piece.length))
            guard Int64(data.count) == piece.length else {
                throw RemoteMacLocalFileError(.read, String(localized: "本地文件在传输途中变短了（偏移 \(String(piece.offset))）"))
            }
            var request = RemoteFileRequest(op: .write, path: path)
            request.offset = UInt64(piece.offset)
            request.writeMode = "write"
            _ = try await perform(request, data)
            onPiece?(piece)
        }
    }

    private static func run(_ pieces: [Range], window: Int,
                            _ work: @escaping @Sendable (Range) async throws -> Void) async throws {
        guard !pieces.isEmpty else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() {
                let piece = pieces[next]
                next += 1
                group.addTask { try await retrying { try await work(piece) } }
            }
            while next < min(max(1, window), pieces.count) { launch() }
            while try await group.next() != nil {
                if next < pieces.count { launch() }
            }
        }
    }

    /// 连接断了、超时这类失败再试；被控端明确拒绝的（没权限、不存在）不试。
    static func retrying<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await work()
            } catch let error as RemoteFileError where (error.code == .unreachable || error.code == .timeout)
                && attempt < attempts {
                try await Task.sleep(for: .milliseconds(300 * attempt))
            }
        }
    }
}

/// 把一台远程 Mac 的文件服务包成 `SFTPProviding`：文件面板、命令行的文件动作都只认这个协议，
/// 接上它就不用写第二套。
actor RemoteMacFileProvider: SFTPProviding {
    /// 发一条请求、等应答。两个方向各有一份：主控端经 `RemoteMacClient` 发给被控的 Mac，
    /// 被控的 Mac 经 `RemoteHostConnection` 反过来发给主控端。
    typealias Send = @Sendable (RemoteFileRequest, Data, Duration?) async throws -> (reply: RemoteFileReply, body: Data)

    private let send: Send

    init(send: @escaping Send) {
        self.send = send
    }

    init(client: RemoteMacClient) {
        self.send = { request, body, timeout in try await client.performFile(request, body: body, timeout: timeout) }
    }

    /// 任意一条文件请求（`SFTPProviding` 之外的搜索、改文件、跑命令都从这里走）。
    nonisolated func perform(_ request: RemoteFileRequest, body: Data = Data(),
                             timeout: Duration? = nil) async throws -> (reply: RemoteFileReply, body: Data) {
        try await send(request, body, timeout)
    }

    private nonisolated var performer: RemoteMacTransfer.Perform {
        { [send] request, body in try await send(request, body, nil) }
    }

    // MARK: - SFTPProviding

    func list(path: String) async throws -> [RemoteEntry] {
        let (reply, _) = try await perform(RemoteFileRequest(op: .list, path: path))
        return (reply.entries ?? []).map(Self.entry)
    }

    nonisolated static func entry(_ item: RemoteFileEntry) -> RemoteEntry {
        RemoteEntry(name: item.name, posixPermissions: item.mode, size: UInt64(max(0, item.size)),
                    modifiedAt: Date(timeIntervalSince1970: item.mtime), uid: item.uid, gid: item.gid,
                    ownerName: item.owner, groupName: item.group)
    }

    func realPath(_ path: String) async throws -> String {
        // SFTP 的 `.` 是登录目录；这里对应主目录。
        let (reply, _) = try await perform(RemoteFileRequest(op: .realpath, path: path == "." ? "~" : path))
        return reply.path ?? path
    }

    func stat(_ path: String) async throws -> RemoteStat {
        let (reply, _) = try await perform(RemoteFileRequest(op: .stat, path: path))
        guard let entry = reply.entry else { throw RemoteFileError(.failed, String(localized: "\(path)：Mac 没有回属性")) }
        return RemoteStat(size: entry.size, mtime: Date(timeIntervalSince1970: entry.mtime), permissions: entry.mode)
    }

    func download(remotePath: String) async throws -> Data {
        try await download(remotePath: remotePath, onProgress: nil)
    }

    func download(remotePath: String, maximumBytes: Int) async throws -> Data {
        let limit = max(0, maximumBytes)
        let size = try await stat(remotePath).size
        if size > Int64(limit) { throw SFTPDownloadLimitExceeded(observedBytes: size, maximumBytes: limit) }
        return try await download(remotePath: remotePath, onProgress: nil)
    }

    func download(remotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        let size = try await stat(remotePath).size
        let buffer = TransferBuffer(count: Int(size))
        let progress = ProgressCounter(total: size, report: onProgress)
        try await RemoteMacTransfer.download(path: remotePath, size: size, perform: performer,
                                             sink: { offset, data in buffer.write(data, at: Int(offset)) },
                                             onPiece: { progress.add($0.length) })
        return buffer.data()
    }

    func download(remotePath: String, toLocalURL localURL: URL,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let size = try await stat(remotePath).size
        // 先写同目录的临时文件，传完再换上去：失败或取消不留半截目标文件，也不毁掉原来的。
        let temporary = localURL.deletingLastPathComponent()
            .appendingPathComponent(".\(localURL.lastPathComponent).uterm-\(UUID().uuidString.prefix(8))")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw RemoteFileError(.failed, String(localized: "本地文件建不了：\(String(cString: strerror(errno)))")) }
        let progress = ProgressCounter(total: size, report: onProgress)
        do {
            try await RemoteMacTransfer.download(path: remotePath, size: size, perform: performer,
                                                 sink: { offset, data in try Self.pwriteAll(fd, data, at: offset) },
                                                 onPiece: { progress.add($0.length) })
            Darwin.close(fd)
            // 同 SFTP 的下载：目标已在就原子替换，不在就直接改名过去。
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: localURL)
            }
        } catch {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func upload(data: Data, toRemotePath: String) async throws {
        try await upload(data: data, toRemotePath: toRemotePath, onProgress: nil)
    }

    func write(_ path: String, data: Data) async throws {
        try await upload(data: data, toRemotePath: path, onProgress: nil)
    }

    func upload(data: Data, toRemotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let data = Data(data)
        try await uploadReplacing(toRemotePath, size: Int64(data.count), onProgress: onProgress) { offset, length in
            data.subdata(in: Int(offset)..<Int(offset) + length)
        }
    }

    func upload(localURL: URL, toRemotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let fd = open(localURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw RemoteFileError(.failed, String(localized: "本地文件打不开：\(String(cString: strerror(errno)))")) }
        defer { Darwin.close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw RemoteFileError(.failed, String(localized: "本地文件读不了属性")) }
        try await uploadReplacing(toRemotePath, size: Int64(info.st_size), onProgress: onProgress) { offset, length in
            try Self.preadAll(fd, at: offset, length: length)
        }
    }

    /// 传到同目录的临时文件，传完改名换上去：读的人看不到半截内容，中途失败原文件还在。
    private func uploadReplacing(_ path: String, size: Int64, onProgress: (@Sendable (TransferProgress) -> Void)?,
                                 source: @escaping @Sendable (Int64, Int) throws -> Data) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let temporary = (directory.isEmpty ? "" : directory + "/") + ".\(name).uterm-\(UUID().uuidString.prefix(8))"
        var create = RemoteFileRequest(op: .write, path: temporary)
        create.writeMode = "create"
        _ = try await perform(create)
        let progress = ProgressCounter(total: size, report: onProgress)
        do {
            try await RemoteMacTransfer.upload(path: temporary, size: size, perform: performer, source: source,
                                               onPiece: { progress.add($0.length) })
            var rename = RemoteFileRequest(op: .rename, path: temporary)
            rename.newPath = path
            rename.options = [RemoteFileOption.replace]
            _ = try await perform(rename)
        } catch {
            _ = try? await perform(RemoteFileRequest(op: .remove, path: temporary))
            throw error
        }
    }

    func writeRange(_ path: String, offset: UInt64, data: Data, mode: SFTPWriteMode) async throws {
        var request = RemoteFileRequest(op: .write, path: path)
        request.offset = offset
        request.writeMode = mode.rawValue
        do {
            // 大于一片的切开：第一片按调用方的打开语义，之后的不能再截断。
            var sent = 0
            repeat {
                let piece = data.subdata(in: data.startIndex + sent..<data.startIndex + min(data.count, sent + RemoteFileLimits.maxChunkBytes))
                request.offset = offset + UInt64(sent)
                _ = try await perform(request, body: piece)
                request.id = UUID()
                request.writeMode = SFTPWriteMode.write.rawValue
                sent += piece.count
            } while sent < data.count
        } catch let error as RemoteFileError where error.code == .exists {
            throw SFTPFileExistsError(path: path)
        }
    }

    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var collected = Data()
        while collected.count < length {
            var request = RemoteFileRequest(op: .read, path: path)
            request.offset = offset + UInt64(collected.count)
            request.length = min(length - collected.count, RemoteFileLimits.maxChunkBytes)
            let (reply, data) = try await perform(request)
            collected.append(data)
            if data.isEmpty || reply.eof == true { break }
        }
        return collected
    }

    func exec(_ command: String) async throws -> String {
        var request = RemoteFileRequest(op: .exec)
        request.command = command
        request.maxBytes = RemoteFileLimits.maxChunkBytes
        let (_, output) = try await perform(request)
        return String(decoding: output, as: UTF8.self)
    }

    func rename(_ path: String, to newPath: String) async throws {
        var request = RemoteFileRequest(op: .rename, path: path)
        request.newPath = newPath
        _ = try await perform(request)
    }

    func removeFile(_ path: String) async throws {
        _ = try await perform(RemoteFileRequest(op: .remove, path: path))
    }

    func removeDirectory(_ path: String) async throws {
        _ = try await perform(RemoteFileRequest(op: .rmdir, path: path))
    }

    func createDirectory(_ path: String) async throws {
        _ = try await perform(RemoteFileRequest(op: .mkdir, path: path))
    }

    func createFile(_ path: String) async throws {
        do {
            _ = try await perform(RemoteFileRequest(op: .createFile, path: path))
        } catch let error as RemoteFileError where error.code == .exists {
            throw SFTPFileExistsError(path: path)
        }
    }

    func setPermissions(path: String, mode: UInt32) async throws {
        var request = RemoteFileRequest(op: .chmod, path: path)
        request.mode = mode & 0o777
        _ = try await perform(request)
    }

    func verifyConnectionAlive() async -> Bool {
        (try? await perform(RemoteFileRequest(op: .realpath, path: "~"), timeout: .seconds(8))) != nil
    }

    /// 连接归 `RemoteMacClient` 的持有者（窗口、命令行的会话表），这里不断开。
    func close() async {}

    // MARK: - 本地读写

    nonisolated static func pwriteAll(_ fd: Int32, _ data: Data, at offset: Int64) throws {
        var done = 0
        while done < data.count {
            let wrote = data.withUnsafeBytes { raw in
                pwrite(fd, raw.baseAddress! + done, data.count - done, off_t(offset) + off_t(done))
            }
            if wrote < 0 {
                if errno == EINTR { continue }
                throw RemoteMacLocalFileError(.write, String(localized: "写本地文件失败：\(String(cString: strerror(errno)))"))
            }
            done += wrote
        }
    }

    nonisolated static func preadAll(_ fd: Int32, at offset: Int64, length: Int) throws -> Data {
        var data = Data(count: length)
        var done = 0
        while done < length {
            let got = data.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + done, length - done, off_t(offset) + off_t(done))
            }
            if got < 0 {
                if errno == EINTR { continue }
                throw RemoteMacLocalFileError(.read, String(localized: "读本地文件失败：\(String(cString: strerror(errno)))"))
            }
            if got == 0 { break }
            done += got
        }
        data.removeSubrange(done..<length)
        return data
    }
}

/// 并发的片各自写进自己的区间。
private nonisolated final class TransferBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data

    init(count: Int) {
        storage = Data(count: count)
    }

    func write(_ data: Data, at offset: Int) {
        lock.lock()
        storage.replaceSubrange(offset..<offset + data.count, with: data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private nonisolated final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    private var emitter: TransferProgressEmitter
    private let total: Int64
    private let report: (@Sendable (TransferProgress) -> Void)?

    init(total: Int64, report: (@Sendable (TransferProgress) -> Void)?) {
        self.total = total
        self.report = report
        emitter = TransferProgressEmitter(totalBytes: total)
    }

    func add(_ bytes: Int64) {
        guard let report else { return }
        lock.lock()
        done += bytes
        let now = done
        let shouldEmit = emitter.shouldEmit(bytesDone: now)
        lock.unlock()
        if shouldEmit { report(TransferProgress(bytesDone: now, bytesTotal: total)) }
    }
}

/// 传输时读写**本机**文件失败（不是远端的错）。命令行据此报 `local_read_failed` / `local_write_failed`，
/// 不靠匹配消息文字（消息随界面语言变）。只在主控端本机产生，不上线路。
nonisolated struct RemoteMacLocalFileError: Error, LocalizedError, Equatable, Sendable {
    enum Direction: Sendable { case read, write }

    let direction: Direction
    let message: String

    init(_ direction: Direction, _ message: String) {
        self.direction = direction
        self.message = message
    }

    var errorDescription: String? { message }
}
