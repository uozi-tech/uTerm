import Foundation
@testable import uTerm

/// 包一层 `SFTPProviding`，数一数各种调用（跑命令、列目录、读区间、取属性）各多少次、各花了多久。
/// 量「重列一次要跑几条命令、读几次」用；只转发，不改任何东西（写入一律拒绝）。
actor AgentHistoryCountingProvider: SFTPProviding {
    let base: any SFTPProviding
    /// 跑不了命令（模拟只许 SFTP 的主机，或者主机上没有 `sqlite3` 的那条退路）。
    let refusesExec: Bool

    private(set) var execs = 0
    private(set) var lists = 0
    private(set) var reads = 0
    private(set) var stats = 0
    private(set) var bytesRead = 0
    private(set) var execTime: Duration = .zero

    nonisolated var escapesRawNames: Bool { base.escapesRawNames }
    nonisolated var execOutputLimit: Int { base.execOutputLimit }

    init(base: any SFTPProviding, refusesExec: Bool = false) {
        self.base = base
        self.refusesExec = refusesExec
    }

    func reset() {
        execs = 0
        lists = 0
        reads = 0
        stats = 0
        bytesRead = 0
        execTime = .zero
    }

    /// 一行摘要（只有数字）。
    var summary: String {
        "exec=\(execs)（\(execTime)） list=\(lists) stat=\(stats) read=\(reads)（\(bytesRead / 1024) KB）"
    }

    func list(path: String) async throws -> [RemoteEntry] {
        lists += 1
        return try await base.list(path: path)
    }

    func realPath(_ path: String) async throws -> String { try await base.realPath(path) }

    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        reads += 1
        let data = try await base.readRange(path, offset: offset, length: length)
        bytesRead += data.count
        return data
    }

    func stat(_ path: String) async throws -> RemoteStat {
        stats += 1
        return try await base.stat(path)
    }

    func exec(_ command: String) async throws -> String {
        execs += 1
        if refusesExec { throw NSError(domain: "sftp-only", code: 1) }
        let started = ContinuousClock.now
        defer { execTime += ContinuousClock.now - started }
        return try await base.exec(command)
    }

    func download(remotePath: String) async throws -> Data {
        reads += 1
        return try await base.download(remotePath: remotePath)
    }

    private func refuse() throws -> Never { throw CancellationError() }
    func upload(data: Data, toRemotePath: String) async throws { try refuse() }
    func write(_ path: String, data: Data) async throws { try refuse() }
    func writeRange(_ path: String, offset: UInt64, data: Data, mode: SFTPWriteMode) async throws { try refuse() }
    func openTransferHandle(_ path: String, writeMode: SFTPWriteMode?) async throws -> SFTPTransferHandle { try refuse() }
    func rename(_ path: String, to newPath: String) async throws { try refuse() }
    func removeFile(_ path: String) async throws { try refuse() }
    func removeDirectory(_ path: String) async throws { try refuse() }
    func createDirectory(_ path: String) async throws { try refuse() }
    func createFile(_ path: String) async throws { try refuse() }
    func setPermissions(path: String, mode: UInt32) async throws { try refuse() }
    func upload(data: Data, toRemotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try refuse()
    }
    func download(remotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        try await download(remotePath: remotePath)
    }
    func download(remotePath: String, toLocalURL localURL: URL, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try refuse()
    }
    func upload(localURL: URL, toRemotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try refuse()
    }
    func close() async {}
}
