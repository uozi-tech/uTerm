import Foundation
import XCTest
@testable import uTerm

/// Antigravity 的搜索命令在**真 shell** 里跑（同 `ClaudeHistorySearchShellTests`）：一棵手写的假数据目录建在测试宿主自己的
/// 临时目录里，命令交给本机的各种登录 shell `-c` 执行（BSD 的 grep 与 awk）。列目录、读区间走 `MockSFTP` 里同样路径的副本。
///
/// 只读：命令只读那棵假目录。内容全是编的。
@MainActor
final class AntigravityHistorySearchShellTests: XCTestCase {
    private typealias F = AntigravityFixture
    private var scratch: URL!
    private var home: String { scratch.appendingPathComponent("home dir 'q'").path }

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("uterm-antigravity-search-" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try await super.tearDown()
    }

    private struct Record {
        let index: Int
        let lines: [String]
        let age: TimeInterval
        var root = ".gemini/antigravity"
        var name = "transcript_full.jsonl"
    }

    /// 个别用例另加的记录。
    private var extraRecords: [Record] = []

    private var records: [Record] {
        baseRecords + extraRecords
    }

    private var baseRecords: [Record] {
        var nasty: [String] = []
        for (index, term) in ClaudeSearchFixture.nastyTerms.enumerated() {
            nasty.append(F.userInput(index * 2, "第 \(index) 句：\(term) 结束"))
        }
        let step = nasty.count * 2
        nasty += [
            F.planner(step, thinking: "只在思考里的 hiddenword", calls: [F.command("echo visiblecall")]),
            F.generic(step + 1, "只在工具结果里的 hiddenword"),
            F.systemMessage(step + 2, "只在系统消息里的 hiddenword"),
            F.userInput(step + 3, "普通的一句", metadata: "只在附加信息里的 hiddenword"),
            F.planner(step + 4, content: "Mixed Case Answer，中文回答"),
        ]
        return [
            Record(index: 1, lines: nasty, age: 60),
            Record(index: 2, lines: [F.userInput(0, "平常的一句 mixed case")], age: 120),
            Record(index: 3, lines: [F.userInput(0, "命令行里的 mixed case"), F.planner(1, content: "好")], age: 30,
                   root: ".gemini/antigravity-cli"),
            Record(index: 4, lines: [F.userInput(0, "删节版里的 mixed case")], age: 200, name: "transcript.jsonl"),
            // 只有系统消息：不列出来，也就不出搜索结果。
            Record(index: 5, lines: [F.systemMessage(0, "系统里的 mixed case")], age: 10),
        ]
    }

    private func path(_ record: Record) -> String {
        "\(home)/\(record.root)/brain/\(F.sessionID(record.index))/.system_generated/logs/\(record.name)"
    }

    /// 写到盘上，再在 `MockSFTP` 里摆一份同样路径的（列目录、读区间走它，`exec` 走真 shell）。
    private func host(shell: String) async throws -> MockSFTP {
        let now = Date()
        var tree: [String: [RemoteEntry]] = [:]
        let sftp = MockSFTP()
        for record in records {
            let data = F.file(record.lines)
            let file = path(record)
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: file))
            tree["\(home)/\(record.root)/brain", default: []].append(
                ClaudeFixture.entry(F.sessionID(record.index), directory: true, mtime: now.addingTimeInterval(-record.age)))
            tree[(file as NSString).deletingLastPathComponent] = [
                ClaudeFixture.entry(record.name, size: UInt64(data.count), mtime: now.addingTimeInterval(-record.age)),
            ]
            await sftp.setFile(file, data: data, mtime: now.addingTimeInterval(-record.age))
        }
        await sftp.setTree(tree)
        let home = self.home
        await sftp.setExecHandler { command in try await Self.run(shell, command, home: home) }
        return sftp
    }

    nonisolated private static func run(_ shell: String, _ command: String, home: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", command]
                process.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    private static var shells: [String] {
        ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/csh", "/bin/tcsh",
         "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func search(_ source: AntigravityHistorySource, _ text: String,
                        limits: AgentHistorySearchLimits = .standard) async throws -> (sessions: [AgentHistorySearchSession], truncated: Bool?) {
        let projects = try await source.projects()
        let files = await source.allSessions(in: projects)
        let sink = SearchSink()
        try await source.search(try AgentHistorySearchQuery.validate(text).get(), in: files, limits: limits) { event in
            sink.record(event)
        }
        return (sink.sessions, sink.truncated)
    }

    private final class SearchSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentHistorySearchSession] = []
        private var finished: Bool?
        var sessions: [AgentHistorySearchSession] { lock.withLock { stored } }
        var truncated: Bool? { lock.withLock { finished } }
        func record(_ event: AgentHistorySearchEvent) {
            lock.withLock {
                switch event {
                case .session(let session): stored.append(session)
                case .finished(let truncated): finished = truncated
                case .progress: break
                }
            }
        }
    }

    func testCommandsRunInEveryLocalShell() async throws {
        let shells = Self.shells
        XCTAssertTrue(shells.contains("/bin/sh"))
        print("[antigravity-search-shell] shells=\(shells.map { ($0 as NSString).lastPathComponent }.joined(separator: ","))")
        for shell in shells {
            let sftp = try await host(shell: shell)
            let source = AntigravityHistorySource(provider: sftp, home: home, searchBatching: ClaudeSearchBatching(files: 2, linesFiles: 2))
            for term in ClaudeSearchFixture.nastyTerms {
                let found = try await search(source, term).sessions
                XCTAssertEqual(found.map(\.file.sessionID), [F.sessionID(1)], "\(shell)：\(term)")
                XCTAssertEqual(found.first?.hits.map(\.snippet.match), [term], "\(shell)：\(term)")
                XCTAssertEqual(found.first?.hits.first?.role, .user, "\(shell)：\(term)")
            }
            // 英文不分大小写、新的在前；两个数据目录、删节版都搜；只有系统消息的会话不出。
            let mixed = try await search(source, "MIXED case")
            XCTAssertEqual(mixed.sessions.map(\.file.sessionID), [3, 1, 2, 4].map(F.sessionID), shell)
            XCTAssertEqual(mixed.truncated, false, shell)
            XCTAssertEqual(mixed.sessions.first { $0.file.sessionID == F.sessionID(1) }?.hits.first?.role, .assistant, shell)
            // 只在思考、工具结果、系统消息、附加信息里的不算；工具调用的摘要算。
            let hidden = try await search(source, "hiddenword").sessions
            XCTAssertEqual(hidden.count, 0, shell)
            let call = try await search(source, "visiblecall").sessions
            XCTAssertEqual(call.first?.hits.first?.snippet.match, "visiblecall", shell)
            let chinese = try await search(source, "中文回答").sessions
            XCTAssertEqual(chinese.first?.hits.first?.snippet.match, "中文回答", shell)

            // 主机报回来的偏移和长度就是那一行；条目 ID 和打开对话后的一致。
            let record = records[0]
            let data = try Data(contentsOf: URL(fileURLWithPath: path(record)))
            let ended = try await search(source, "结束").sessions
            let session = try XCTUnwrap(ended.first)
            XCTAssertEqual(session.hits.count, AgentHistorySearchLimits.standard.hitsPerSession, shell)
            XCTAssertTrue(session.hasMoreHits, shell)
            for hit in session.hits {
                let start = Int(hit.anchor.lineOffset)
                XCTAssertTrue(start == 0 || data[start - 1] == 0x0A, shell)
                XCTAssertEqual(data[start + hit.anchor.lineLength], 0x0A, shell)
                XCTAssertEqual(hit.itemID, "\(start).0", shell)
            }
        }
    }

    /// 思考里命中的行不占「每份最多报几行」的名额：前面四十步只在思考里有这个词，第四十一步的回答里才有，照样搜得到。
    func testThinkingDoesNotUseUpTheCandidateBudget() async throws {
        var lines: [String] = []
        for step in 0..<40 {
            lines.append(F.planner(step, thinking: "想着 budgetword 第 \(step) 次", calls: [F.command("true")]))
        }
        lines.append(F.userInput(40, "说说", metadata: "附加信息里的 budgetword"))
        lines.append(F.planner(41, content: "回答里的 budgetword"))
        extraRecords = [Record(index: 6, lines: lines, age: 300)]
        let sftp = try await host(shell: "/bin/sh")
        let source = AntigravityHistorySource(provider: sftp, home: home)
        let found = try await search(source, "budgetword").sessions
        XCTAssertEqual(found.map(\.file.sessionID), [F.sessionID(6)])
        XCTAssertEqual(found.first?.hits.map(\.role), [.assistant])
        XCTAssertEqual(found.first?.hits.first?.snippet.match, "budgetword")
    }

    func testTotalLimitStopsEarly() async throws {
        let sftp = try await host(shell: "/bin/sh")
        let source = AntigravityHistorySource(provider: sftp, home: home)
        var limits = AgentHistorySearchLimits.standard
        limits.totalHits = 2
        let result = try await search(source, "mixed case", limits: limits)
        XCTAssertEqual(result.sessions.flatMap(\.hits).count, 2)
        XCTAssertEqual(result.truncated, true)
    }

    /// 命令里的东西都是编码过的：搜索词就算像一段 shell 命令，也只是被当成字去找。
    func testSearchTermIsNeverExecuted() async throws {
        let marker = scratch.appendingPathComponent("pwned")
        let sftp = try await host(shell: "/bin/sh")
        let source = AntigravityHistorySource(provider: sftp, home: home)
        for term in ["'; touch \(marker.path); '", "\"; touch \(marker.path); \"", "$(touch \(marker.path))",
                     "`touch \(marker.path)`", "\\'; touch \(marker.path) #"] {
            _ = try await search(source, term)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// 主机只许 SFTP：跑不了命令就说搜不了。
    func testHostWithoutExecCannotSearch() async throws {
        let sftp = try await host(shell: "/bin/sh")
        await sftp.setExecHandler { _ in throw NSError(domain: "exec", code: 1) }
        let source = AntigravityHistorySource(provider: sftp, home: home)
        // `list(path: home)` 在假主机上能列（返回空），所以算「连接还在、只是跑不了命令」。
        do {
            _ = try await search(source, "mixed case")
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? AgentHistorySearchError, .cannotExecute)
        }
    }

    /// 搜到之后从命中处打开：第一页以那一条结束。
    func testOpensTheHit() async throws {
        let sftp = try await host(shell: "/bin/sh")
        let source = AntigravityHistorySource(provider: sftp, home: home)
        let found = try await search(source, "Mixed Case Answer").sessions
        let session = try XCTUnwrap(found.first)
        let hit = try XCTUnwrap(session.hits.first)
        let page = try await source.transcript(for: session.file, around: hit.anchor).loadPrevious()
        // 命中那一行最后还跟着这一步的用量（不画），停在画出来的最后一条上。
        let shown = page.items.last(where: \.isDisplayed)
        XCTAssertEqual(shown?.id, hit.itemID)
        XCTAssertEqual(shown?.kind, .assistantText("Mixed Case Answer，中文回答"))
    }
}
