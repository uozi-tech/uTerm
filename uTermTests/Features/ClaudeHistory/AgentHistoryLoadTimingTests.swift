import Foundation
import XCTest
@testable import uTerm

/// Code 标签页侧栏「列出来要多久」：在测试自己的临时目录里造一份和真实规模相当的 `~/.claude/projects`
/// （245 个项目、1672 份记录，内容全是编的），经包内的辅助程序读（同 App 里的本机 Code 标签页），量从开连接到
/// 列表出第一行、出满一屏的时间。冷启动（新开一个 Code 标签页）和有缓存（之前开过一个）各量几次。
///
/// 量时间的用例默认跳过（机器忙时读数没意义），开关 `UTERM_HISTORY_TIMING=1`（xcodebuild 加 `TEST_RUNNER_` 前缀）。
/// 不读这台机器上的真实记录。
@MainActor
final class AgentHistoryLoadTimingTests: XCTestCase {
    private var client: LocalShellAgentClient!
    private var home: URL!

    static let projectCount = 245
    static let sessionCount = 1672

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["UTERM_HISTORY_TIMING"] == "1" else {
            throw XCTSkip("没设 UTERM_HISTORY_TIMING=1，跳过量时间的用例")
        }
        client = LocalShellAgentClient()
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        home = base.appendingPathComponent("history-timing-\(UUID().uuidString)")
        try Self.makeHome(at: home)
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        client?.invalidate()
        AgentHistoryListCache.shared.removeAll()
        try await super.tearDown()
    }

    /// 一份记录：一行用户、一行助手、一个标题，再垫一些行凑到几十 KB（同真实记录的末尾那一块要读的量）。
    static func record(project: String, index: Int) -> Data {
        let cwd = "/Users/someone/work/\(project)"
        var lines = [ClaudeFixture.userText("第 \(index) 个问题", cwd: cwd)]
        for line in 0..<40 {
            lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock(String(repeating: "回答 \(line) ", count: 30)),
                                                 uuid: "a-\(line)", cwd: cwd))
        }
        lines.append(ClaudeFixture.aiTitle("会话 \(project) #\(index)"))
        return ClaudeFixture.file(lines)
    }

    static func makeHome(at home: URL) throws {
        let root = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        let now = Date()
        var made = 0
        for p in 0..<projectCount {
            let name = "-Users-someone-work-p\(p)"
            let dir = root.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let count = sessionCount / projectCount + (p < sessionCount % projectCount ? 1 : 0)
            for s in 0..<count {
                let url = dir.appendingPathComponent(UUID().uuidString.lowercased() + ".jsonl")
                try record(project: "p\(p)", index: s).write(to: url)
                let age = TimeInterval(made) * 600
                try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
                made += 1
            }
        }
    }

    private func connection() -> AgentHistoryConnection {
        let client = self.client!
        return AgentHistoryConnection(preferredDirectory: nil, home: home.path, tools: AgentHistoryTool.allCases,
                                      followsCurrentProject: false, cacheKey: "timing:\(home.path)",
                                      connect: { _ in RemoteMacFileProvider.localShellAgent(client: client) })
    }

    /// 开连接到列表出第一行 / 出满一屏（24 行）各要多久。
    private func measureOpen() async throws -> (first: Duration, page: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let connection = connection()
        let opening = Task { await connection.open() }
        var first: Duration?
        while true {
            if let history = connection.history {
                let shown = history.visibleFiles.count
                if first == nil, shown > 0 { first = start.duration(to: clock.now) }
                if shown >= 24 { break }
            }
            guard start.duration(to: clock.now) < .seconds(120) else { XCTFail("两分钟还没列出来"); break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let page = start.duration(to: clock.now)
        _ = await opening.value
        connection.close()
        return (first ?? page, page)
    }

    func test_open_timing() async throws {
        var lines: [String] = []
        for round in 0..<3 {
            AgentHistoryListCache.shared.removeAll()
            let cold = try await measureOpen()
            let warm = try await measureOpen()
            lines.append("round \(round): cold first=\(cold.first) page=\(cold.page); cached first=\(warm.first) page=\(warm.page)")
        }
        print("[history-timing] " + lines.joined(separator: "\n[history-timing] "))
    }

    /// 侧栏后台重列（Code 标签页里有会话在跑时每 10 秒一次、会话结束时一次）期间，列表会不会空掉：最新的那份记录
    /// 一直在写（跑着的会话），另在主目录对应的项目里新建一份（在 `~` 新开的会话）。记下重列时列表最少剩几行。
    func test_background_refresh_keeps_rows() async throws {
        let connection = connection()
        await connection.open()
        let history = try XCTUnwrap(connection.history)
        for _ in 0..<500 where history.visibleFiles.count < 24 { try await Task.sleep(for: .milliseconds(10)) }
        let root = home.appendingPathComponent(".claude/projects")
        let newProject = root.appendingPathComponent("-Users-someone")
        try FileManager.default.createDirectory(at: newProject, withIntermediateDirectories: true)
        let fresh = newProject.appendingPathComponent(UUID().uuidString.lowercased() + ".jsonl")
        try ClaudeFixture.file([ClaudeFixture.noise(1)]).write(to: fresh)
        let top = try XCTUnwrap(history.files.first?.path)
        var minimum = Int.max
        var emptyFiles = 0
        let writer = Task.detached {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: top))
            for _ in 0..<60 {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((ClaudeFixture.noise(2) + "\n").utf8))
                try await Task.sleep(for: .milliseconds(50))
            }
            try handle.close()
        }
        let reloads = Task {
            for _ in 0..<8 {
                await history.reload(showsLoading: false)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        while !reloads.isCancelled {
            minimum = min(minimum, history.visibleFiles.count)
            if history.files.isEmpty { emptyFiles += 1 }
            try await Task.sleep(for: .milliseconds(3))
            if await reloadsDone(reloads) { break }
        }
        _ = try? await writer.value
        print("[history-refresh] minimum visible rows during background refresh: \(minimum); samples with no files: \(emptyFiles)")
        connection.close()
        XCTAssertGreaterThan(minimum, 0, "后台重列时列表不能空掉")
    }

    private func reloadsDone(_ task: Task<Void, Never>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(for: .milliseconds(1)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
