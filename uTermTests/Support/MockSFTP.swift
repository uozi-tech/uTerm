import Foundation
@testable import uTerm

/// 可控的 `SFTPProviding` 测试替身。
actor MockSFTP: SFTPProviding {
    var tree: [String: [RemoteEntry]]
    private(set) var uploads: [(path: String, bytes: Int)] = []
    private(set) var downloads: [String] = []
    private(set) var didClose = false
    var listError: Error?
    private(set) var renames: [(from: String, to: String)] = []
    private(set) var removedFiles: [String] = []
    private(set) var removedDirs: [String] = []
    private(set) var createdDirs: [String] = []
    private(set) var createdFiles: [String] = []
    private(set) var permissionChanges: [(path: String, mode: UInt32)] = []
    private(set) var execCommands: [String] = []

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
        if let listError { throw listError }
        return tree[path] ?? []
    }

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

    func upload(data: Data, toRemotePath: String) async throws {
        uploads.append((toRemotePath, data.count))
    }

    // MARK: - SFTPProviding write / stat

    func write(_ path: String, data: Data) async throws {
        blobStore[path] = (data, Date())
    }

    func stat(_ path: String) async throws -> RemoteStat {
        guard let entry = blobStore[path] else {
            throw NSError(domain: "MockSFTP", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no such file: \(path)"
            ])
        }
        return RemoteStat(size: Int64(entry.0.count), mtime: entry.1)
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
    func exec(_ command: String) async throws -> String {
        execCommands.append(command)
        return execOutput
    }
    func setExecOutput(_ s: String) { execOutput = s }

    func rename(_ path: String, to newPath: String) async throws {
        renames.append((path, newPath))
    }
    func removeFile(_ path: String) async throws { removedFiles.append(path) }
    func removeDirectory(_ path: String) async throws { removedDirs.append(path) }
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
