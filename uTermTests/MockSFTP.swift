import Foundation
@testable import uTerm

/// 可控的 `SFTPProviding` 测试替身。
actor MockSFTP: SFTPProviding {
    var tree: [String: [RemoteEntry]]
    private(set) var uploads: [(path: String, bytes: Int)] = []
    private(set) var downloads: [String] = []
    private(set) var didClose = false
    var listError: Error?

    /// 内存 blob 存储：path → (data, mtime)。write / read / stat 均走此存储。
    private var blobStore: [String: (Data, Date)] = [:]

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

    func close() async { didClose = true }

    func setListError(_ error: Error) { listError = error }
}
