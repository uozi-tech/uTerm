import Foundation
@testable import uTerm

/// 可控的 `SFTPProviding` 测试替身。
actor MockSFTP: SFTPProviding {
    var tree: [String: [RemoteEntry]]
    private(set) var uploads: [(path: String, bytes: Int)] = []
    private(set) var downloads: [String] = []
    private(set) var boundedDownloads: [(path: String, maximumBytes: Int)] = []
    private(set) var streamingUploads: [(localURL: URL, remotePath: String)] = []
    private(set) var streamingDownloads: [(remotePath: String, localURL: URL)] = []
    private(set) var didClose = false
    var listError: Error?
    private(set) var renames: [(from: String, to: String)] = []
    private(set) var removedFiles: [String] = []
    private(set) var removedDirs: [String] = []
    private(set) var createdDirs: [String] = []
    private(set) var createdFiles: [String] = []
    private(set) var permissionChanges: [(path: String, mode: UInt32)] = []
    private(set) var execCommands: [String] = []
    private var blockExec = false
    private var execReleased = false
    private var execStarted = false

    /// 内存 blob 存储：path → (data, mtime)。write / read / stat 均走此存储。
    private var blobStore: [String: (Data, Date)] = [:]

    /// 当为 true 时，带进度的 upload/download 会挂起直到 `release()`，并在挂起期间
    /// 响应 Task 取消（用于测试并发上限 / 取消 / 完成时机）。默认 false = 立即完成。
    var blockTransfers = false
    private var released = false
    /// 这些远程路径的 upload 会抛错（测试失败态）。
    var failingUploadPaths: Set<String> = []
    private var uploadPartialProgress: (bytesDone: Int64, delayNanoseconds: UInt64)?

    func release() { released = true }
    func setBlockTransfers(_ v: Bool) { blockTransfers = v }
    func setFailingUploadPaths(_ paths: Set<String>) { failingUploadPaths = paths }
    func setUploadPartialProgress(bytesDone: Int64, delayNanoseconds: UInt64) {
        uploadPartialProgress = (bytesDone, delayNanoseconds)
    }

    /// 当 blockTransfers 时挂起直到 release；其间每 2ms 检查一次取消。
    private func awaitReleaseIfBlocking() async throws {
        guard blockTransfers else { return }
        while !released {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    init(tree: [String: [RemoteEntry]] = [:]) {
        self.tree = tree
    }

    func list(path: String) async throws -> [RemoteEntry] {
        listCalls.append(path)
        while heldListPaths.contains(path) {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if let listError { throw listError }
        if let error = listErrorsByPath[path] { throw error }
        return tree[path] ?? []
    }

    // MARK: - 按路径的列目录闸门 / 错误（测试加载代次、列失败留在原目录）

    /// 依次被列过的路径。
    private(set) var listCalls: [String] = []
    /// 这些路径的 `list` 挂起，直到 `releaseList(_:)`。
    private var heldListPaths: Set<String> = []
    /// 只对这些路径抛的列目录错误（`listError` 对所有路径生效）。
    private var listErrorsByPath: [String: Error] = [:]

    func holdList(_ path: String) { heldListPaths.insert(path) }
    func releaseList(_ path: String) { heldListPaths.remove(path) }
    func setListError(_ error: Error, at path: String) { listErrorsByPath[path] = error }

    func realPath(_ path: String) async throws -> String {
        path == "." ? "/home/user" : path
    }

    /// `download` 先查 blobStore，找不到则回落旧行为（path 拼字符串）。
    func download(remotePath: String) async throws -> Data {
        downloads.append(remotePath)
        if let entry = blobStore[remotePath] {
            return entry.0
        }
        return Data("file:\(remotePath)".utf8)
    }

    func download(remotePath: String, maximumBytes: Int) async throws -> Data {
        let limit = max(0, maximumBytes)
        boundedDownloads.append((remotePath, limit))
        let metadata = try await stat(remotePath)
        if metadata.size > Int64(limit) {
            throw SFTPDownloadLimitExceeded(observedBytes: metadata.size, maximumBytes: limit)
        }
        let data = try await download(remotePath: remotePath)
        guard data.count <= limit else {
            throw SFTPDownloadLimitExceeded(observedBytes: Int64(data.count), maximumBytes: limit)
        }
        return data
    }

    func upload(data: Data, toRemotePath: String) async throws {
        uploads.append((toRemotePath, data.count))
    }

    // MARK: - SFTPProviding write / stat

    func write(_ path: String, data: Data) async throws {
        wholeWriteCount += 1
        if holdsWholeWrites {
            await withCheckedContinuation { heldWholeWrites.append($0) }
        }
        if let wholeWriteError { throw wholeWriteError }
        blobStore[path] = (data, Date())
    }

    /// `write`（整文件写，编辑器保存走这条）被调了几次。
    private(set) var wholeWriteCount = 0
    /// `write` 抛这个错（断线、没权限）。
    private var wholeWriteError: Error?
    func setWholeWriteError(_ error: Error?) { wholeWriteError = error }
    /// 置位时 `write` 挂起到 `releaseWholeWrites()`：模拟保存途中用户接着打字。
    private var holdsWholeWrites = false
    private var heldWholeWrites: [CheckedContinuation<Void, Never>] = []
    var heldWholeWriteCount: Int { heldWholeWrites.count }
    func setHoldsWholeWrites(_ value: Bool) { holdsWholeWrites = value }
    func releaseWholeWrites() {
        holdsWholeWrites = false
        let held = heldWholeWrites
        heldWholeWrites.removeAll()
        for continuation in held { continuation.resume() }
    }

    // MARK: - 区间读写（分片传输的原语）

    /// 每次 `writeRange` 的记录，供断言分片的 offset / mode 覆盖。
    private(set) var rangeWrites: [(path: String, offset: UInt64, bytes: Int, mode: SFTPWriteMode)] = []
    /// 每次 `readRange` 的记录。
    private(set) var rangeReads: [(path: String, offset: UInt64, length: Int)] = []
    func clearRangeReads() { rangeReads.removeAll() }

    /// 让 `writeRange` 在**写阶段**失败（磁盘满 / 配额 / 断线）：文件已经被建出来
    /// （`stat` 查得到），只是内容没落盘。用来验证 handler 不会把这种失败误报成
    /// `file_exists`。
    private var writeStageError: Error?
    /// 让 `writeRange` 在**打开阶段**失败，错误按 `SFTPWriteStageError(stage: .open)`
    /// 包好 —— handler 只对这一档做「是不是已存在」的 stat 兜底。
    private var openStageError: Error?

    func setWriteStageError(_ error: Error?) { writeStageError = error }
    func setOpenStageError(_ error: Error?) { openStageError = error }

    /// 内存版随机写：`create` 撞已存在文件抛 `SFTPFileExistsError`（与真实 EXCL 同一归类），
    /// `overwrite` 先截断，`write` 保留既有内容只覆盖 `[offset, offset+count)`；
    /// 越过末尾写留 0 空洞（POSIX 语义）。
    func writeRange(_ path: String, offset: UInt64, data: Data,
                    mode: SFTPWriteMode) async throws {
        if failingUploadPaths.contains(path) {
            throw NSError(domain: "MockSFTP", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "upload failed: \(path)"])
        }
        if let openStageError {
            // 打开就没成；路径照样落一份，好验证 handler 的 stat 兜底确实在这一档生效。
            if blobStore[path] == nil { blobStore[path] = (Data(), Date()) }
            throw SFTPWriteStageError(stage: .open, underlying: openStageError)
        }
        if let writeStageError {
            // EXCL 打开成功 → 文件已经存在 → 兜底 stat 必然命中。写失败原样抛，
            // handler 若还做那次兜底就会把「磁盘满」报成 file_exists。
            if blobStore[path] == nil { blobStore[path] = (Data(), Date()) }
            throw writeStageError
        }
        var base: Data
        switch mode {
        case .create:
            if blobStore[path] != nil { throw SFTPFileExistsError(path: path) }
            base = Data()
        case .overwrite:
            base = Data()
        case .write:
            base = blobStore[path]?.0 ?? Data()
        }
        let start = Int(clamping: offset)
        if base.count < start { base.append(Data(count: start - base.count)) }
        let end = start + data.count
        if base.count < end { base.append(Data(count: end - base.count)) }
        if !data.isEmpty { base.replaceSubrange(start..<end, with: data) }
        blobStore[path] = (base, Date())
        rangeWrites.append((path, offset, data.count, mode))
    }

    /// 内存版区间读：到 EOF 会短。
    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        rangeReads.append((path, offset, length))
        guard let all = blobStore[path]?.0 else {
            throw NSError(domain: "MockSFTP", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no such file: \(path)"
            ])
        }
        guard length > 0 else { return Data() }
        let start = min(Int(clamping: offset), all.count)
        let end = min(start + length, all.count)
        guard start < end else { return Data() }
        return all.subdata(in: start..<end)
    }

    /// 用指定 mtime 写入测试文件，覆盖“同一秒、等长改写”这类仅靠 stat 无法识别的场景。
    func setFile(_ path: String, data: Data, mtime: Date) {
        blobStore[path] = (data, mtime)
    }

    /// `stat` 要回的权限位（原始 POSIX mode，含类型位）。没登记就是 nil，
    /// 对应「服务端没给 `SSH_FILEXFER_ATTR_PERMISSIONS`」。
    private var statPermissions: [String: UInt32] = [:]

    func setStatPermissions(_ path: String, _ mode: UInt32) {
        statPermissions[path] = mode
    }

    /// 让 `stat` 抛出指定错误（用真实的 SFTP 错误值构造错误映射用例）。
    var statError: Error?

    func setStatError(_ error: Error?) { statError = error }

    /// 每次 `stat` 的路径（数「看了几次文件末尾」）。
    private(set) var statCalls: [String] = []

    func stat(_ path: String) async throws -> RemoteStat {
        statCalls.append(path)
        if let statError { throw statError }
        guard let entry = blobStore[path] else {
            throw NSError(domain: "MockSFTP", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no such file: \(path)"
            ])
        }
        return RemoteStat(
            size: Int64(entry.0.count),
            mtime: entry.1,
            permissions: statPermissions[path]
        )
    }

    // MARK: - Helpers

    /// read：别名 download，供测试直接调用（保持 write→read round-trip 语义）。
    func read(_ path: String) async throws -> Data {
        try await download(remotePath: path)
    }

    func downloadedPaths() -> [String] {
        downloads
    }

    /// 遥测 exec 的可控返回值（默认空串 = 无遥测）。
    var execOutput: String = ""
    /// 有它时 `exec` 交给它答（假主机：照命令的意思现算输出，见 `ClaudeSearchHostEmulator`）。
    private var execHandler: (@Sendable (String) async throws -> String)?
    func setExecHandler(_ handler: (@Sendable (String) async throws -> String)?) { execHandler = handler }
    func exec(_ command: String) async throws -> String {
        execCommands.append(command)
        execStarted = true
        while blockExec && !execReleased {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(2))
        }
        if let execHandler { return try await execHandler(command) }
        return execOutput
    }

    /// 内存里某个文件的内容（假主机照它答搜索命令）。
    func fileData(_ path: String) -> Data? { blobStore[path]?.0 }
    func setExecOutput(_ s: String) { execOutput = s }
    func setBlockExec(_ value: Bool) {
        blockExec = value
        execReleased = !value
        execStarted = false
    }
    func releaseExec() { execReleased = true }
    func didStartExec() -> Bool { execStarted }

    func rename(_ path: String, to newPath: String) async throws {
        renames.append((path, newPath))
    }
    func removeFile(_ path: String) async throws {
        try await gateRemoval(path)
        removedFiles.append(path)
    }
    func removeDirectory(_ path: String) async throws {
        try await gateRemoval(path)
        removedDirs.append(path)
    }

    // MARK: - 删除闸门（测试递归删除的进度 / 取消）

    /// 为 true 时每次 remove 都挂起，直到 `releaseRemovals()`；用于在删除进行中
    /// 观察 `FileBrowserModel.deletion` 的中间态、或在中途请求取消。
    private var blockRemovals = false
    private var removalsReleased = false
    /// 这些路径的 remove 会抛错（测试中途失败）。
    private var failingRemovePaths: Set<String> = []

    /// 指定路径的 remove 抛出**给定的错误对象**（`failingRemovePaths` 只会抛
    /// NSError；错误映射用例要拿真实的 SFTP 错误值来试）。
    private var removeErrors: [String: Error] = [:]

    func setRemoveError(_ path: String, _ error: Error) { removeErrors[path] = error }

    func setBlockRemovals(_ v: Bool) { blockRemovals = v }
    func releaseRemovals() { removalsReleased = true }
    func setFailingRemovePaths(_ paths: Set<String>) { failingRemovePaths = paths }
    func setTree(_ newTree: [String: [RemoteEntry]]) { tree = newTree }

    private func gateRemoval(_ path: String) async throws {
        while blockRemovals && !removalsReleased {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if let error = removeErrors[path] { throw error }
        if failingRemovePaths.contains(path) {
            throw NSError(domain: "MockSFTP", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "remove denied: \(path)"])
        }
    }
    func createDirectory(_ path: String) async throws { createdDirs.append(path) }
    /// 新建空文件：记录路径供断言，并把空 blob 落库（mirror 真实 EXCL：路径
    /// 已存在则抛错，不覆盖）。
    func createFile(_ path: String) async throws {
        if blobStore[path] != nil {
            throw NSError(domain: "MockSFTP", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: "file exists: \(path)"])
        }
        createdFiles.append(path)
        blobStore[path] = (Data(), Date())
    }
    func setPermissions(path: String, mode: UInt32) async throws {
        permissionChanges.append((path, mode & 0o777))
    }

    func upload(data: Data, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        let total = Int64(data.count)
        onProgress?(TransferProgress(bytesDone: 0, bytesTotal: total))
        if failingUploadPaths.contains(toRemotePath) {
            throw NSError(domain: "MockSFTP", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "upload failed: \(toRemotePath)"])
        }
        if let uploadPartialProgress {
            try await Task.sleep(nanoseconds: uploadPartialProgress.delayNanoseconds)
            onProgress?(TransferProgress(
                bytesDone: min(uploadPartialProgress.bytesDone, total),
                bytesTotal: total))
        }
        try await awaitReleaseIfBlocking()
        onProgress?(TransferProgress(bytesDone: total, bytesTotal: total))
        uploads.append((toRemotePath, data.count))
    }
    func download(remotePath: String,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        let d = try await download(remotePath: remotePath)   // records `downloads`
        onProgress?(TransferProgress(bytesDone: 0, bytesTotal: Int64(d.count)))
        try await awaitReleaseIfBlocking()
        onProgress?(TransferProgress(bytesDone: Int64(d.count), bytesTotal: Int64(d.count)))
        return d
    }

    func upload(localURL: URL, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        streamingUploads.append((localURL, toRemotePath))
        let data = try Data(contentsOf: localURL)
        try await upload(data: data, toRemotePath: toRemotePath, onProgress: onProgress)
    }

    func download(remotePath: String, toLocalURL localURL: URL,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        streamingDownloads.append((remotePath, localURL))
        let data = try await download(remotePath: remotePath)
        onProgress?(TransferProgress(bytesDone: 0, bytesTotal: Int64(data.count)))
        try await awaitReleaseIfBlocking()
        try Task.checkCancellation()
        try data.write(to: localURL, options: .atomic)
        onProgress?(TransferProgress(bytesDone: Int64(data.count), bytesTotal: Int64(data.count)))
    }

    func close() async { didClose = true }

    func setListError(_ error: Error) { listError = error }

    // MARK: - 存活探测（ConnectionWatchdog 路径）

    /// 探测返回值（默认 true=活）。记录调用次数供断言。
    var aliveOnProbe = true
    private(set) var probeCount = 0
    func setAliveOnProbe(_ v: Bool) { aliveOnProbe = v }
    func verifyConnectionAlive() async -> Bool {
        probeCount += 1
        return aliveOnProbe
    }
}
