import Foundation
@testable import uTerm

/// 可控的 `SFTPProviding` 测试替身。
actor MockSFTP: SFTPProviding {
    var tree: [String: [RemoteEntry]]
    private(set) var uploads: [(path: String, bytes: Int)] = []
    private(set) var downloads: [String] = []
    private(set) var didClose = false
    var listError: Error?

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

    func download(remotePath: String) async throws -> Data {
        downloads.append(remotePath)
        return Data("file:\(remotePath)".utf8)
    }

    func upload(data: Data, toRemotePath: String) async throws {
        uploads.append((toRemotePath, data.count))
    }

    func close() async { didClose = true }

    func setListError(_ error: Error) { listError = error }
}
