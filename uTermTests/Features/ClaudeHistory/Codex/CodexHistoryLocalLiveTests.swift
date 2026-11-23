import XCTest
@testable import uTerm

/// 「历史会话」的 Codex 数据源在**这台 Mac 的真实记录**（`~/.codex/sessions`）上跑一遍，走包内的辅助程序，同 App。
///
/// 会读你自己的 Codex 记录，所以**默认跳过**，开关是 `UTERM_CODEX_HISTORY_LOCAL=1`（xcodebuild 传环境变量要加
/// `TEST_RUNNER_` 前缀）。可选 `UTERM_CODEX_HISTORY_SAMPLE`：读多少份的信息（缺省 80，新的在前）。
///
/// **只读**：不往 `~/.codex` 写任何东西。日志与失败信息里只有条数、字节数和耗时，没有标题、路径或对话内容。
@MainActor
final class CodexHistoryLocalLiveTests: XCTestCase {
    private var client: LocalShellAgentClient!
    private var provider: RemoteMacFileProvider!

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["UTERM_CODEX_HISTORY_LOCAL"] == "1" else {
            throw XCTSkip("没设 UTERM_CODEX_HISTORY_LOCAL=1，跳过读本机真实 Codex 记录的测试")
        }
        client = LocalShellAgentClient()
        provider = RemoteMacFileProvider.localShellAgent(client: client)
    }

    override func tearDown() async throws {
        client?.invalidate()
        try await super.tearDown()
    }

    private var sampleSize: Int {
        ProcessInfo.processInfo.environment["UTERM_CODEX_HISTORY_SAMPLE"].flatMap(Int.init) ?? 80
    }

    private func loaded(_ source: CodexHistorySource) async throws -> [AgentHistoryProject] {
        let projects = try await source.projects()
        guard !projects.isEmpty else { throw XCTSkip("这台 Mac 上没有命令行起的 Codex 会话") }
        return projects
    }

    /// 首屏：列目录 + 读全部开头（主机命令）多久；只许 SFTP 的退路多久；信息抽样。
    func testListsRealRecords() async throws {
        let source = CodexHistorySource(provider: provider)
        var started = ContinuousClock.now
        let root = try await source.sessionsRoot()
        let files = try await source.listRecordFiles(root: root)
        let listFiles = ContinuousClock.now - started
        started = ContinuousClock.now
        let projects = try await loaded(source)
        let firstScreen = ContinuousClock.now - started
        let sessions = await source.allSessions(in: projects)
        let execs = await source.canExecute
        let zstd = await source.hostHasZstd
        let compressed = files.filter(\.isCompressed).count

        // 第二遍（刷新）：开头读过的不再读。
        started = ContinuousClock.now
        _ = try await source.projects()
        let rescan = ContinuousClock.now - started

        // 只许 SFTP 的退路：同一棵记录，一份份读开头。
        let sftpOnly = CodexHistorySource(provider: SFTPOnly(base: provider))
        started = ContinuousClock.now
        let sftpProjects = try await sftpOnly.projects()
        let sftpScreen = ContinuousClock.now - started
        // 只比是不是一样，不打印（失败信息里不能有真实路径）。
        let sameProjects = Set(sftpProjects.map(\.id)) == Set(projects.map(\.id))
        XCTAssertTrue(sameProjects, "两条路列出来的项目不一样（\(sftpProjects.count) / \(projects.count) 个）")

        var listed = 0, hidden = 0, untitled = 0, failed = 0, resumable = 0
        let sample = Array(sessions.prefix(sampleSize))
        started = ContinuousClock.now
        for file in sample {
            guard let info = try? await source.metadata(for: file) else {
                failed += 1
                continue
            }
            if info.isListed { listed += 1 } else { hidden += 1 }
            if info.title == nil { untitled += 1 }
            if let directory = info.resumeDirectory, source.resumeCommand(sessionID: file.sessionID, directory: directory) != nil {
                resumable += 1
            }
        }
        let metadataTime = ContinuousClock.now - started
        XCTAssertEqual(failed, 0, "有 \(failed) 份读不出信息")
        print("""
            [codex-history-local] files=\(files.count) compressed=\(compressed) listDirs=\(listFiles) \
            firstScreen=\(firstScreen) rescan=\(rescan) sftpOnlyFirstScreen=\(sftpScreen) exec=\(String(describing: execs)) \
            zstd=\(String(describing: zstd)) projects=\(projects.count) sessions=\(sessions.count) \
            sampled=\(sample.count) in \(metadataTime): listed=\(listed) hidden=\(hidden) untitled=\(untitled) \
            resumable=\(resumable) failed=\(failed)
            """)
    }

    /// 打开最大的几份和最新的几份：第一页多久、整份能不能翻到头；另外逐行数一数有多少行解析不了。
    func testOpensRealTranscripts() async throws {
        let source = CodexHistorySource(provider: provider)
        let projects = try await loaded(source)
        let sessions = await source.allSessions(in: projects)
        var candidates: [AgentHistorySessionFile] = []
        for file in sessions.prefix(sampleSize) {
            if let info = try? await source.metadata(for: file), info.isListed { candidates.append(file) }
        }
        let largestPlain = candidates.filter { !$0.path.hasSuffix(".zst") }.max { $0.size < $1.size }
        let largestCompressed = candidates.filter { $0.path.hasSuffix(".zst") }.max { $0.size < $1.size }
        let picked = [largestPlain, largestCompressed].compactMap { $0 } + candidates.prefix(4)
        XCTAssertFalse(picked.isEmpty)
        var badLines = 0, lines = 0, tooLarge = 0
        for file in picked {
            let pager = source.transcript(for: file)
            let started = ContinuousClock.now
            var items: [AgentTranscriptItem] = []
            var reachedStart = false
            var pages = 0
            do {
                while !reachedStart, pages < 200 {
                    let page = try await pager.loadPrevious()
                    if pages == 0 {
                        print("[codex-history-local] first page bytes=\(file.size) compressed=\(file.path.hasSuffix(".zst")) in \(ContinuousClock.now - started)")
                    }
                    items = page.items + items
                    reachedStart = page.reachedStart
                    pages += 1
                }
            } catch {
                // 超过上限的压缩记录：说得清的错误，不是崩溃。
                tooLarge += 1
                print("[codex-history-local] transcript bytes=\(file.size) not opened (limit)")
                continue
            }
            XCTAssertEqual(Set(items.map(\.id)).count, items.count, "条目 ID 有重复")
            let oversized = items.filter { if case .oversized = $0.kind { return true } else { return false } }.count
            print("""
                [codex-history-local] transcript bytes=\(file.size) pages=\(pages) items=\(items.count) \
                oversized=\(oversized) reachedStart=\(reachedStart) in \(ContinuousClock.now - started)
                """)
            // 逐行：JSON 解析不了的有几行。
            guard file.size < 64 * 1024 * 1024 else { continue }
            let data: Data
            if file.path.hasSuffix(".zst") {
                data = (try? await CodexCompressedPager.download(provider: provider, path: file.path,
                                                                 maxDecodedBytes: CodexArchiveLimits.maxDecodedBytes)) ?? Data()
            } else {
                data = (try? await provider.readRange(file.path, offset: 0, length: Int(file.size))) ?? Data()
            }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                lines += 1
                if (try? JSONSerialization.jsonObject(with: Data(line))) == nil { badLines += 1 }
            }
        }
        print("[codex-history-local] scanned lines=\(lines) bad=\(badLines) tooLarge=\(tooLarge)")
    }

    /// 搜一个常见英文词（`UTERM_CODEX_HISTORY_SEARCH` 可换）。只打印数字。
    func testSearchesRealRecords() async throws {
        let term = ProcessInfo.processInfo.environment["UTERM_CODEX_HISTORY_SEARCH"] ?? "test"
        let query = try AgentHistorySearchQuery.validate(term).get()
        let source = CodexHistorySource(provider: provider)
        let projects = try await loaded(source)
        let files = await source.allSessions(in: projects)
        let coverage = await source.searchCoverage(of: files)
        let recorder = Recorder()
        let started = ContinuousClock.now
        try await source.search(query, in: files, limits: .standard) { event in recorder.record(event) }
        print("""
            [codex-history-search] files=\(files.count) compressed=\(files.filter { $0.path.hasSuffix(".zst") }.count) \
            unsearchable=\(coverage.unsearchable) sessionsWithHits=\(recorder.sessions) hits=\(recorder.hits) \
            firstResult=\(recorder.first.map { "\($0 - started)" } ?? "none") total=\(ContinuousClock.now - started)
            """)
        XCTAssertTrue(recorder.finished)
    }
}

/// 同一个提供者，但跑不了命令（模拟只许 SFTP 的主机）。
private actor SFTPOnly: SFTPProviding {
    let base: any SFTPProviding
    init(base: any SFTPProviding) { self.base = base }
    func list(path: String) async throws -> [RemoteEntry] { try await base.list(path: path) }
    func realPath(_ path: String) async throws -> String { try await base.realPath(path) }
    func download(remotePath: String) async throws -> Data { try await base.download(remotePath: remotePath) }
    func upload(data: Data, toRemotePath: String) async throws { throw CancellationError() }
    func write(_ path: String, data: Data) async throws { throw CancellationError() }
    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        try await base.readRange(path, offset: offset, length: length)
    }
    func stat(_ path: String) async throws -> RemoteStat { try await base.stat(path) }
    func exec(_ command: String) async throws -> String { throw NSError(domain: "sftp-only", code: 1) }
    func rename(_ path: String, to newPath: String) async throws { throw CancellationError() }
    func removeFile(_ path: String) async throws { throw CancellationError() }
    func removeDirectory(_ path: String) async throws { throw CancellationError() }
    func createDirectory(_ path: String) async throws { throw CancellationError() }
    func createFile(_ path: String) async throws { throw CancellationError() }
    func setPermissions(path: String, mode: UInt32) async throws { throw CancellationError() }
    func upload(data: Data, toRemotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        throw CancellationError()
    }
    func download(remotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        try await base.download(remotePath: remotePath)
    }
    func download(remotePath: String, toLocalURL localURL: URL, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        throw CancellationError()
    }
    func upload(localURL: URL, toRemotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        throw CancellationError()
    }
    func close() async {}
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var state = (sessions: 0, hits: 0, first: ContinuousClock.Instant?.none, finished: false)
    func record(_ event: AgentHistorySearchEvent) {
        lock.withLock {
            switch event {
            case .session(let session):
                state.sessions += 1
                state.hits += session.hits.count
                if state.first == nil { state.first = .now }
            case .finished: state.finished = true
            case .progress: break
            }
        }
    }
    var sessions: Int { lock.withLock { state.sessions } }
    var hits: Int { lock.withLock { state.hits } }
    var first: ContinuousClock.Instant? { lock.withLock { state.first } }
    var finished: Bool { lock.withLock { state.finished } }
}
