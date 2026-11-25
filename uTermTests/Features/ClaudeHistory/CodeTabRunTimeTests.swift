import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// Code 标签页里跑着的会话，侧栏那一行的「多久以前」跟着记录最新的写入走（同大小一起变），不停在列出来的那一刻。
///
/// 用真的 `ClaudeHistorySource` 读内存里的假主机（`SQLiteTestHost`），记录照真实的 Claude Code 2.1.x 写法：
/// 一轮里夹着不带时间戳的行（`api-request-blob`、`attachment`、`file-history-snapshot`），文件一直在长。
///
/// 起因（2026-11-25，build 1500）：App 重启后约 25 秒的截图上，接回的会话那一行写「33 分钟前 · 6.2 MB」，看着像停在了
/// 重启时列到的样子。核对记录：截图时文件确实是 6.2 MB（下一行写入在截图之后），时间也是当时文件的修改时间（会话在等输入），
/// 之后后台重读照常跟上。这里钉住「接回的、正在写的会话，那一行的大小与时间跟着记录走」（数据和画出来的字两层）；
/// 停着不写时字不往前走的那一半见 `AgentSessionTimeTextTests`。
@MainActor
final class CodeTabRunTimeTests: XCTestCase {
    private static let home = "/home/user"
    private static let directory = "/home/user/shop"
    private static var projectDirectory: String {
        ClaudeProjectPath.projectsRoot(home: home) + "/" + ClaudeProjectPath.encode(directory)
    }

    private final class FakeTerminal: CodeTabTerminal {
        let id: UUID
        var codeCommandHasEnded = false
        init(id: UUID = UUID()) { self.id = id }
        func runCodeCommand(_ command: String) {}
        func dispose() {}
    }

    override func setUp() async throws {
        try await super.setUp()
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        try await super.tearDown()
    }

    // MARK: 假记录

    private static func path(_ id: String) -> String { projectDirectory + "/\(id).jsonl" }

    /// 一轮：提问、标题、工具调用与结果，夹着不带时间戳的行（真实 2.1.x 文件里很多）。
    private static func turn(prompt: String?, title: String?, toolLines: Int) -> [String] {
        var lines: [String] = []
        if let prompt {
            lines.append(ClaudeFixture.userText(prompt, cwd: directory))
            lines.append(ClaudeFixture.lastPrompt(prompt))
        }
        if let title { lines.append(ClaudeFixture.aiTitle(title)) }
        let padding = String(repeating: "x", count: 1024)
        for index in 0..<toolLines {
            lines.append(#"{"type":"api-request-blob","sessionId":"s","blob":"\#(padding)"}"#)
            lines.append(ClaudeFixture.assistant(ClaudeFixture.toolUse(id: "t\(index)", name: "Bash",
                                                                       input: #"{"command":"ls"}"#), cwd: directory))
            lines.append(ClaudeFixture.user(content: #"[{"tool_use_id":"t\#(index)","type":"tool_result","content":"\#(padding)"}]"#,
                                            cwd: directory))
            lines.append(#"{"type":"attachment","attachment":{"type":"todo","content":[]},"sessionId":"s"}"#)
        }
        lines.append(#"{"type":"file-history-snapshot","messageId":"m","snapshot":{"trackedFileBackups":{}}}"#)
        return lines
    }

    private func append(_ host: SQLiteTestHost, _ id: String, _ lines: [String], mtime: Date = Date()) async {
        var data = await host.data(Self.path(id)) ?? Data()
        data.append(ClaudeFixture.file(lines))
        await host.put(Self.path(id), data, mtime: mtime)
    }

    private func started(_ host: SQLiteTestHost) async -> AgentHistoryModel {
        let source = ClaudeHistorySource(provider: host, home: Self.home)
        let history = AgentHistoryModel(source: source, preferredDirectory: Self.directory, followsCurrentProject: false)
        await history.start()
        for _ in 0..<400 where history.hasMore || history.isListing {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return history
    }

    /// 侧栏那一行的第二行（同 `AgentHistorySessionRow`）。
    private func subtitle(_ history: AgentHistoryModel, _ id: String) -> String? {
        guard let file = history.visibleFiles.first(where: { $0.sessionID == id }) else { return nil }
        return AgentHistoryText.sessionSubtitle(file, metadata: history.metadata[file.path], showsProject: false,
                                                activity: history.liveActivity(of: file))
    }

    // MARK: 用例

    /// 重启后接回的会话（只知道工具 + 会话 ID，列表列出来之后找回记录）：记录接着写，那一行的时间与大小都跟上，
    /// 并排到最上面（按日期分组的「今天」里也在最前面）。
    func testRestoredRunRowTracksTheRecordWhileItGrows() async throws {
        let host = SQLiteTestHost(home: Self.home)
        let id = "7c1e5a90-2b4d-4f6e-9a01-3c5d7e9f1b2a"
        // 重启前写到 33 分钟前；同目录里还有一个别的会话，5 分钟前写过。
        await append(host, id, Self.turn(prompt: "Code 视图侧边栏", title: "Code 视图侧边栏与 Desktop 差异",
                                         toolLines: 20), mtime: Date().addingTimeInterval(-33 * 60))
        await append(host, "other", Self.turn(prompt: "别的", title: "别的会话", toolLines: 5),
                     mtime: Date().addingTimeInterval(-5 * 60))
        let history = await started(host)

        let code = CodeTabModel(hostName: "mac", directory: Self.directory) { _ in FakeTerminal() }
        code.timing = .init(check: .milliseconds(20), refresh: .milliseconds(60))
        code.install(AgentHistoryConnection(history: history))
        defer { code.close() }
        let terminal = FakeTerminal()
        let record = CodeTabRecord(id: UUID(), hostName: "mac", directory: Self.directory, runs: [
            CodeRunRecord(session: terminal.id, tool: .claude, sessionID: id, directory: Self.directory,
                          startedAt: Date().addingTimeInterval(-3600), marker: nil),
        ], selectedRun: terminal.id)
        code.restore(record, terminals: [terminal.id: terminal])
        try await waitUntil("接回的会话找回记录") { code.runs.first?.path == Self.path(id) }
        XCTAssertEqual(subtitle(history, id)?.hasPrefix(AgentHistoryText.relative(Date().addingTimeInterval(-33 * 60))),
                       true, "刚接回：还是重启前那一刻")

        // Claude Code 接着写（重启后），时间是现在。
        await append(host, id, Self.turn(prompt: nil, title: nil, toolLines: 30))
        let grown = await host.data(Self.path(id))?.count ?? 0
        let size = UInt64(grown).formatted(.byteCount(style: .file))
        try await waitUntil("那一行的大小跟上") { self.subtitle(history, id)?.contains(size) == true }
        let now = AgentHistoryText.relative(Date())
        XCTAssertEqual(subtitle(history, id)?.hasPrefix(now), true,
                       "时间同大小一起跟上：\(subtitle(history, id) ?? "nil")")
        XCTAssertEqual(history.files.first?.sessionID, id, "最近写过的排在最上面")
    }

    /// 画出来的侧栏（同 Code 标签页：跑着的会话在它那一组里自己那一行上，`AgentHistoryRunning`）：记录接着写、后台重读之后，
    /// 那一行画出来的字里大小和时间都换成新的。
    func testRunRowOnScreenTracksTheRecord() async throws {
        AccessibilityTreeForTests.enable(for: self)
        let host = SQLiteTestHost(home: Self.home)
        let id = "7c1e5a90-2b4d-4f6e-9a01-3c5d7e9f1b2a"
        await append(host, id, Self.turn(prompt: "Code 视图侧边栏", title: "Code 视图侧边栏与 Desktop 差异",
                                         toolLines: 20), mtime: Date().addingTimeInterval(-33 * 60))
        await append(host, "other", Self.turn(prompt: "别的", title: "别的会话", toolLines: 5),
                     mtime: Date().addingTimeInterval(-5 * 60))
        let history = await started(host)
        let code = CodeTabModel(hostName: "mac", directory: Self.directory) { _ in FakeTerminal() }
        code.timing = .init(check: .milliseconds(20), refresh: .seconds(3600))
        code.install(AgentHistoryConnection(history: history))
        defer { code.close() }
        let terminal = FakeTerminal()
        code.restore(CodeTabRecord(id: UUID(), hostName: "mac", directory: Self.directory, runs: [
            CodeRunRecord(session: terminal.id, tool: .claude, sessionID: id, directory: Self.directory,
                          startedAt: Date().addingTimeInterval(-3600)),
        ], selectedRun: terminal.id), terminals: [terminal.id: terminal])
        try await waitUntil("接回的会话找回记录") { code.runs.first?.path == Self.path(id) }

        let list = AgentHistorySessionList(history: history, running: AgentHistoryRunning(rows: {
            code.runs.map { run in
                AgentHistoryRunRow(id: run.id, title: code.title(of: run), tool: run.tool, directory: run.directory,
                                   isSelected: false, path: run.path, status: AgentHistoryRunStatus { .unreported })
            }
        }, onSelect: { _ in }))
        let view = NSHostingView(rootView: list.frame(width: 320, height: 500))
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        let window = ProbeWindow.make(contentRect: view.frame, contentView: view)
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        func runRowText() async throws -> String? {
            for _ in 0..<5 {
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            return Self.axStrings(view).first { $0.contains("Code 视图侧边栏与 Desktop 差异") }
        }
        let drawn = try await runRowText()
        let before = try XCTUnwrap(drawn, "画出了跑着的会话那一行")
        XCTAssertTrue(before.contains(AgentHistoryText.relative(Date().addingTimeInterval(-33 * 60))), before)

        await append(host, id, Self.turn(prompt: nil, title: nil, toolLines: 30))
        await code.refreshRunRecords()
        let size = UInt64(await host.data(Self.path(id))?.count ?? 0).formatted(.byteCount(style: .file))
        let redrawn = try await runRowText()
        let after = try XCTUnwrap(redrawn)
        XCTAssertTrue(after.contains(size), "大小跟上：\(after)")
        XCTAssertTrue(after.contains(AgentHistoryText.relative(Date())), "时间跟上：\(after)")
    }

    // MARK: 工具

    /// 子树里所有无障碍元素的 label / value（同 `ForwardingListContractTests`）。
    private static func axStrings(_ root: Any, depth: Int = 0) -> [String] {
        guard depth < 60 else { return [] }
        var out: [String] = []
        let object = root as AnyObject
        if let label = object.accessibilityLabel?(), !label.isEmpty { out.append(label) }
        let valueSelector = NSSelectorFromString("accessibilityValue")
        if object.responds?(to: valueSelector) == true,
           let value = object.perform(valueSelector)?.takeUnretainedValue() as? String, !value.isEmpty {
            out.append(value)
        }
        if let children = object.accessibilityChildren?() {
            for child in children { out += axStrings(child, depth: depth + 1) }
        }
        return out
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("等「\(what)」超时", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
