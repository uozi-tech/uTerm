import Foundation
import XCTest
@testable import uTerm

/// 搜索命令在**真 shell** 里跑：一棵手写的假记录目录建在测试宿主自己的临时目录里，命令交给本机的各种登录 shell
/// （`/bin/sh`、bash、zsh、dash、csh、tcsh，装了 fish 也跑）`-c` 执行——这台 Mac 上就是 BSD 的 grep 与 awk。
/// 另有一条经包内不带沙盒的辅助程序（`uTermShellAgent.xpc`，用你的登录 shell `-l -c`，同 App 读本机记录的那条路）。
///
/// 只读：命令只读那棵假目录，不写任何东西。内容全是编的。
@MainActor
final class ClaudeHistorySearchShellTests: XCTestCase {
    private typealias F = ClaudeSearchFixture
    private var scratch: URL!
    private var home: String { scratch.appendingPathComponent("home dir 'q'").path }
    private var root: String { ClaudeProjectPath.projectsRoot(home: home) }
    private let project = "-home-user-projects-demo"

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("uterm-claude-search-" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(atPath: root + "/" + project, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try await super.tearDown()
    }

    private var sessions: [(id: String, data: Data, age: TimeInterval)] {
        var nasty: [String] = []
        for (index, term) in F.nastyTerms.enumerated() {
            nasty.append(ClaudeFixture.userText("第 \(index) 句：\(term) 结束", uuid: "u-\(index)"))
        }
        nasty.append(ClaudeFixture.assistant(ClaudeFixture.thinkingBlock("只在思考里的 hiddenword")))
        nasty.append(ClaudeFixture.toolResult(id: "t1", text: "只在工具结果里的 hiddenword"))
        nasty.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("Mixed Case Answer，中文回答")))
        return [
            (F.sessionID(1), F.session(nasty, title: "怪字符"), 60),
            (F.sessionID(2), F.session([ClaudeFixture.userText("平常的一句 mixed case")], title: "平常"), 120),
            (F.sessionID(3), F.session([ClaudeFixture.userText("桌面版 mixed case", entrypoint: "claude-desktop")], title: "桌面版"), 30),
        ]
    }

    /// 写到盘上，再在 `MockSFTP` 里摆一份同样路径的（列目录、读区间走它，`exec` 走真 shell）。
    private func host(shell: String) async throws -> MockSFTP {
        let now = Date()
        var entries: [RemoteEntry] = []
        let sftp = MockSFTP()
        for session in sessions {
            let path = "\(root)/\(project)/\(session.id).jsonl"
            try session.data.write(to: URL(fileURLWithPath: path))
            entries.append(ClaudeFixture.entry("\(session.id).jsonl", size: UInt64(session.data.count),
                                               mtime: now.addingTimeInterval(-session.age)))
            await sftp.setFile(path, data: session.data, mtime: now.addingTimeInterval(-session.age))
        }
        await sftp.setTree([root: [ClaudeFixture.entry(project, directory: true, mtime: now)], "\(root)/\(project)": entries])
        let home = self.home
        await sftp.setExecHandler { command in try await Self.run(shell, command, home: home) }
        return sftp
    }

    /// 像 sshd 那样：登录 shell `-c` 整串命令，标准输出与标准错误合在一起。
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

    private func search(_ source: ClaudeHistorySource, _ text: String) async throws -> [AgentHistorySearchSession] {
        let projects = try await source.projects()
        let files = await source.allSessions(in: projects)
        let found = SearchSink()
        try await source.search(try AgentHistorySearchQuery.validate(text).get(), in: files, limits: .standard) { event in
            if case .session(let session) = event { found.append(session) }
        }
        return found.sessions
    }

    private final class SearchSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentHistorySearchSession] = []
        var sessions: [AgentHistorySearchSession] { lock.withLock { stored } }
        func append(_ session: AgentHistorySearchSession) { lock.withLock { stored.append(session) } }
    }

    func testCommandsRunInEveryLocalShell() async throws {
        let shells = Self.shells
        XCTAssertTrue(shells.contains("/bin/sh"))
        print("[claude-search-shell] shells=\(shells.map { ($0 as NSString).lastPathComponent }.joined(separator: ","))")
        for shell in shells {
            let sftp = try await host(shell: shell)
            let source = ClaudeHistorySource(provider: sftp, home: home)
            for term in F.nastyTerms {
                let found = try await search(source, term)
                XCTAssertEqual(found.map(\.file.sessionID), [F.sessionID(1)], "\(shell)：\(term)")
                XCTAssertEqual(found.first?.hits.map(\.snippet.match), [term], "\(shell)：\(term)")
            }
            // 英文不分大小写、新的在前、桌面版不出；只在思考和工具结果里的不算。
            let mixed = try await search(source, "MIXED case")
            XCTAssertEqual(mixed.map(\.file.sessionID), [F.sessionID(1), F.sessionID(2)], shell)
            XCTAssertEqual(mixed.first?.hits.first?.role, .assistant, shell)
            let hidden = try await search(source, "hiddenword")
            XCTAssertEqual(hidden.count, 0, shell)
            let chinese = try await search(source, "中文回答")
            XCTAssertEqual(chinese.first?.hits.first?.snippet.match, "中文回答", shell)

            // 主机报回来的偏移和长度就是那一行（BSD awk 在 `LC_ALL=C` 下按字节数）。
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/\(project)/\(F.sessionID(1)).jsonl"))
            for hit in try await search(source, "结束").first?.hits ?? [] {
                let start = Int(hit.anchor.lineOffset)
                XCTAssertTrue(start == 0 || data[start - 1] == 0x0A, shell)
                XCTAssertEqual(data[start + hit.anchor.lineLength], 0x0A, shell)
            }
        }
    }

    /// 命令里的东西都是编码过的：搜索词就算像一段 shell 命令，也只是被当成字去找，不会被执行。
    func testSearchTermIsNeverExecuted() async throws {
        let marker = scratch.appendingPathComponent("pwned")
        let sftp = try await host(shell: "/bin/sh")
        let source = ClaudeHistorySource(provider: sftp, home: home)
        for term in ["'; touch \(marker.path); '", "\"; touch \(marker.path); \"", "$(touch \(marker.path))",
                     "`touch \(marker.path)`", "\\'; touch \(marker.path) #"] {
            _ = try await search(source, term)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// 经包内的辅助程序：你的登录 shell `-l -c`（配置文件都会读），读的是盘上那棵假目录。
    func testSearchesThroughTheShellAgent() async throws {
        _ = try await host(shell: "/bin/sh")   // 只为把文件写到盘上
        let client = LocalShellAgentClient()
        defer { client.invalidate() }
        let provider = RemoteMacFileProvider.localShellAgent(client: client)
        let source = ClaudeHistorySource(provider: provider, home: home)
        for term in F.nastyTerms {
            let found = try await search(source, term)
            XCTAssertEqual(found.map(\.file.sessionID), [F.sessionID(1)], term)
            XCTAssertEqual(found.first?.hits.map(\.snippet.match), [term], term)
        }

        // 搜到之后从命中处打开：第一页以那一条结束，后面按需往后读。
        let model = AgentHistoryModel(source: source, preferredDirectory: nil)
        await model.start()
        model.searchText = "Mixed Case Answer"
        model.submitSearch()
        for _ in 0..<500 where model.search?.phase != .finished { try await Task.sleep(for: .milliseconds(10)) }
        let session = try XCTUnwrap(model.search?.sessions.first)
        let hit = try XCTUnwrap(session.hits.first)
        model.openHit(hit, in: session)
        let transcript = try XCTUnwrap(model.transcript)
        for _ in 0..<500 where transcript.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(transcript.items.last?.id, hit.itemID)
        XCTAssertEqual(transcript.highlightedItemID, hit.itemID)
    }
}
