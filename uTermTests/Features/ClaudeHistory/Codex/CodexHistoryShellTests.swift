import Foundation
import XCTest
@testable import uTerm

/// 主机命令在**真 shell** 里跑（同 `ClaudeHistorySearchShellTests`）：一棵手写的假 `~/.codex/sessions` 建在测试宿主的临时目录里，
/// 列表读开头、搜索两段都交给本机的各种登录 shell `-c`（这台 Mac 上是 BSD 的 head / grep / awk）。
///
/// 测试沙盒里跑不了真的 `zstd`：压缩的记录旁边放一份解开的 `<文件>.plain`，`bin/zstd` 是个只会 `cat` 它的假 `zstd`。
/// 这样核的是命令怎么调 `zstd`、偏移是不是解开后的位置；解压本身由 `CodexZstdTests` 核。假的也跑不起来（沙盒不让执行
/// 临时目录里的脚本）时，这几条按「主机上没有 zstd」核。只读，内容全是编的。
@MainActor
final class CodexHistoryShellTests: XCTestCase {
    private typealias F = CodexFixture
    private var scratch: URL!
    private var home: String { scratch.appendingPathComponent("home dir 'q'").path }
    private var root: String { home + "/.codex/sessions" }
    private var bin: String { scratch.appendingPathComponent("bin").path }
    private let quotedCwd = "/home/u/it's \"中\" dir"
    private let desktop = "019a0000-3333-7444-8555-666677778888"
    private let second = "019a0000-2222-7333-8444-555566667777"

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("uterm-codex-shell-" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let shim = "#!/bin/sh\n# 假 zstd：只认 -dcq -- <文件>，吐出旁边解开的那份。\nfor last; do :; done\nexec cat \"$last.plain\"\n"
        try Data(shim.utf8).write(to: URL(fileURLWithPath: bin + "/zstd"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/zstd")
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try await super.tearDown()
    }

    private var records: [(relative: String, data: Data, age: TimeInterval)] {
        var nasty = [F.meta(cwd: quotedCwd), F.injected]
        for (index, term) in ClaudeSearchFixture.nastyTerms.enumerated() {
            nasty.append(F.user("第 \(index) 句：\(term) 结束", ordinal: index + 1))
        }
        nasty.append(F.reasoning("只在思考里的 hiddenword"))
        nasty.append(F.customOutput(callID: "c1", text: "只在工具结果里的 hiddenword"))
        nasty.append(F.developer("只在系统提示里的 hiddenword"))
        nasty.append(F.assistant("Mixed Case Answer，中文回答"))
        return [
            ("2026/11/20/rollout-2026-11-20T10-00-00-\(F.threadID).jsonl", F.file(nasty), 60),
            ("2026/11/19/rollout-2026-11-19T10-00-00-\(second).jsonl", F.session(id: second, prompt: "平常的一句 mixed case"), 120),
            ("2026/11/18/rollout-2026-11-18T10-00-00-\(desktop).jsonl",
             F.session(id: desktop, originator: "Codex Desktop", prompt: "桌面版 mixed case"), 30),
            ("2026/11/01/rollout-2026-11-01T09-00-00-\(CodexZstdFixture.threadID).jsonl.zst", CodexZstdFixture.small, 900),
        ]
    }

    /// 写到盘上，再在 `MockSFTP` 里摆一份同样路径的（列目录、读区间走它，`exec` 走真 shell）。
    private func host(shell: String, withZstd: Bool) async throws -> MockSFTP {
        let now = Date()
        var files: [(path: String, data: Data, mtime: Date)] = []
        for record in records {
            let path = root + "/" + record.relative
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try record.data.write(to: URL(fileURLWithPath: path))
            if path.hasSuffix(".zst") {
                try CodexZstdStream.decompress(record.data).write(to: URL(fileURLWithPath: path + ".plain"))
            }
            files.append((path, record.data, now.addingTimeInterval(-record.age)))
        }
        let sftp = await Self.mirror(files, root: root)
        let home = self.home
        let path = (withZstd ? bin + ":" : "") + "/usr/bin:/bin:/usr/sbin:/sbin"
        await sftp.setExecHandler { command in try await Self.run(shell, command, home: home, path: path) }
        return sftp
    }

    private static func mirror(_ files: [(path: String, data: Data, mtime: Date)], root: String) async -> MockSFTP {
        var tree: [String: [RemoteEntry]] = [:]
        for file in files {
            var directory = (file.path as NSString).deletingLastPathComponent
            tree[directory, default: []].append(F.entry((file.path as NSString).lastPathComponent, size: UInt64(file.data.count),
                                                        mtime: file.mtime))
            while directory.count > root.count {
                let parent = (directory as NSString).deletingLastPathComponent
                let name = (directory as NSString).lastPathComponent
                if !(tree[parent] ?? []).contains(where: { $0.name == name }) {
                    tree[parent, default: []].append(F.entry(name, directory: true))
                }
                directory = parent
            }
        }
        let sftp = MockSFTP(tree: tree)
        for file in files { await sftp.setFile(file.path, data: file.data, mtime: file.mtime) }
        return sftp
    }

    nonisolated private static func run(_ shell: String, _ command: String, home: String, path: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", command]
                process.environment = ["HOME": home, "PATH": path, "SHELL": shell]
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
        ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/csh", "/bin/tcsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 假的 zstd 在这个沙盒里跑不跑得起来。
    private func shimWorks() async throws -> Bool {
        let probe = scratch.appendingPathComponent("probe.zst").path
        try Data("ok".utf8).write(to: URL(fileURLWithPath: probe + ".plain"))
        let output = try await Self.run("/bin/sh", "zstd -dcq -- '\(probe)'", home: home, path: bin + ":/usr/bin:/bin")
        return output == "ok"
    }

    private func search(_ source: CodexHistorySource, _ text: String) async throws -> [AgentHistorySearchSession] {
        let projects = try await source.projects()
        let files = await source.allSessions(in: projects)
        let found = Sink()
        try await source.search(try AgentHistorySearchQuery.validate(text).get(), in: files, limits: .standard) { event in
            if case .session(let session) = event { found.append(session) }
        }
        return found.sessions
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentHistorySearchSession] = []
        var sessions: [AgentHistorySearchSession] { lock.withLock { stored } }
        func append(_ session: AgentHistorySearchSession) { lock.withLock { stored.append(session) } }
    }

    // MARK: - 列表

    /// 读开头那条命令：每种 shell 都读得出字段（目录带引号、双引号、中文），一份一行；SFTP 只用来列目录，不读开头。
    func testHeadersComeFromOneCommandInEveryShell() async throws {
        let zstdWorks = try await shimWorks()
        for shell in Self.shells {
            let sftp = try await host(shell: shell, withZstd: zstdWorks)
            let source = CodexHistorySource(provider: sftp, home: home)
            let projects = try await source.projects()
            XCTAssertEqual(projects.map(\.id), [F.cwd, quotedCwd, CodexZstdFixture.cwd], "\(shell)：新的在前")
            let sessions = await source.allSessions(in: projects)
            XCTAssertEqual(sessions.count, 4, shell)
            let reads = await sftp.rangeReads
            XCTAssertEqual(reads.filter { !$0.path.hasSuffix(".zst") }.count, 0, "\(shell)：明文的开头是命令读的")
            XCTAssertEqual(reads.isEmpty, zstdWorks, "\(shell)：主机上没有 zstd 时压缩的那份走 SFTP")
            let commands = await sftp.execCommands
            XCTAssertEqual(commands.count, 1, shell)
            let hasZstd = await source.hostHasZstd
            XCTAssertEqual(hasZstd, zstdWorks, shell)
        }
        print("[codex-shell] shells=\(Self.shells.map { ($0 as NSString).lastPathComponent }.joined(separator: ",")) zstdShim=\(zstdWorks)")
    }

    /// 一批放不下：分好几条命令，结果对得上各自的文件。
    func testHeaderBatchesSplit() async throws {
        let sftp = try await host(shell: "/bin/sh", withZstd: false)
        var listing = CodexListing()
        listing.headerBatching.files = 1
        let source = CodexHistorySource(provider: sftp, home: home, listing: listing)
        let projects = try await source.projects()
        XCTAssertEqual(Set(projects.map(\.id)), [quotedCwd, F.cwd, CodexZstdFixture.cwd])
        let commands = await sftp.execCommands
        XCTAssertEqual(commands.count, 4)
    }

    // MARK: - 搜索

    func testSearchRunsInEveryShell() async throws {
        let zstdWorks = try await shimWorks()
        for shell in Self.shells {
            let sftp = try await host(shell: shell, withZstd: zstdWorks)
            let source = CodexHistorySource(provider: sftp, home: home)
            for term in ClaudeSearchFixture.nastyTerms {
                let found = try await search(source, term)
                XCTAssertEqual(found.map(\.file.sessionID), [F.threadID], "\(shell)：\(term)")
                XCTAssertEqual(found.first?.hits.map(\.snippet.match), [term], "\(shell)：\(term)")
            }
            // 英文不分大小写、新的在前、桌面版不出；只在思考、工具结果、系统提示里的不算。
            let mixed = try await search(source, "MIXED case")
            XCTAssertEqual(mixed.map(\.file.sessionID), [F.threadID, second], shell)
            XCTAssertEqual(mixed.first?.hits.first?.role, .assistant, shell)
            let hidden = try await search(source, "hiddenword")
            XCTAssertEqual(hidden.count, 0, shell)

            // 主机报回来的偏移和长度就是那一行。
            let data = try Data(contentsOf: URL(fileURLWithPath: root + "/" + records[0].relative))
            for hit in try await search(source, "结束").first?.hits ?? [] {
                let start = Int(hit.anchor.lineOffset)
                XCTAssertTrue(start == 0 || data[start - 1] == 0x0A, shell)
                XCTAssertEqual(data[start + hit.anchor.lineLength], 0x0A, shell)
            }

            // 压缩的：有 zstd 时照搜（偏移是解开后的位置），没有时跳过、能说出跳过了几份。
            let zebra = try await search(source, "zebra")
            let projects = try await source.projects()
            let files = await source.allSessions(in: projects)
            let coverage = await source.searchCoverage(of: files)
            if zstdWorks {
                XCTAssertEqual(zebra.map(\.file.sessionID), [CodexZstdFixture.threadID], shell)
                XCTAssertEqual(zebra.first?.hits.map(\.role), [.user, .assistant], shell)
                XCTAssertEqual(coverage, .complete, shell)
                // 从命中处打开：第一页以那一条结束。
                let hit = try XCTUnwrap(zebra.first?.hits.first)
                let hitFile = try XCTUnwrap(zebra.first?.file)
                let pager = source.transcript(for: hitFile, around: hit.anchor)
                let page = try await pager.loadPrevious()
                XCTAssertEqual(page.items.last?.id, hit.itemID, shell)
            } else {
                XCTAssertEqual(zebra.count, 0, shell)
                XCTAssertEqual(coverage, AgentHistorySearchCoverage(unsearchable: 1, reason: .missingDecompressor), shell)
            }
        }
    }

    /// 命令里的东西都是编码过的：搜索词就算像一段 shell 命令，也只是被当成字去找。
    func testSearchTermIsNeverExecuted() async throws {
        let marker = scratch.appendingPathComponent("pwned")
        let sftp = try await host(shell: "/bin/sh", withZstd: false)
        let source = CodexHistorySource(provider: sftp, home: home)
        for term in ["'; touch \(marker.path); '", "\"; touch \(marker.path); \"", "$(touch \(marker.path))",
                     "`touch \(marker.path)`", "\\'; touch \(marker.path) #"] {
            _ = try await search(source, term)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// 经包内不带沙盒的辅助程序（你的登录 shell `-l -c`，同 App 读本机记录的那条路）：这里 `PATH` 里多半有真的 `zstd`，
    /// 压缩的那份由主机命令读开头、搜索、带回命中行。没有 `zstd` 的机器上核「跳过并说出跳过了几份」。
    func testThroughTheShellAgent() async throws {
        _ = try await host(shell: "/bin/sh", withZstd: false)   // 只为把文件写到盘上
        let client = LocalShellAgentClient()
        defer { client.invalidate() }
        let provider = RemoteMacFileProvider.localShellAgent(client: client)
        let source = CodexHistorySource(provider: provider, home: home)
        let projects = try await source.projects()
        XCTAssertEqual(Set(projects.map(\.id)), [quotedCwd, F.cwd, CodexZstdFixture.cwd])
        let canExecute = await source.canExecute
        XCTAssertEqual(canExecute, true)
        let zstdState = await source.hostHasZstd
        let hasZstd = try XCTUnwrap(zstdState)
        print("[codex-shell] shell agent zstd=\(hasZstd)")
        let term = ClaudeSearchFixture.nastyTerms[0]
        let found = try await search(source, term)
        XCTAssertEqual(found.first?.hits.map(\.snippet.match), [term])
        let zebra = try await search(source, "ZEBRA")
        if hasZstd {
            XCTAssertEqual(zebra.map(\.file.sessionID), [CodexZstdFixture.threadID])
            XCTAssertEqual(zebra.first?.hits.map(\.snippet.match), ["Zebra", "Zebra"])
            let hit = try XCTUnwrap(zebra.first?.hits.last)
            let hitFile = try XCTUnwrap(zebra.first?.file)
            let page = try await source.transcript(for: hitFile, around: hit.anchor).loadPrevious()
            XCTAssertEqual(page.items.last?.id, hit.itemID)
            XCTAssertEqual(page.items.last?.kind, .assistantText("压缩记录里的回答 Zebra done"))
        } else {
            XCTAssertEqual(zebra.count, 0)
        }
    }

    /// 只许 SFTP 的主机：列表照样列得出来（全走 SFTP），搜索报「跑不了命令」。
    func testSFTPOnlyHost() async throws {
        let sftp = try await host(shell: "/bin/sh", withZstd: false)
        await sftp.setExecHandler { _ in
            try await Task.sleep(for: .milliseconds(20))
            throw NSError(domain: "test", code: 1)
        }
        // 一份一批、几批同时发：第一批失败时别的还在跑，取消掉的那几批也要走 SFTP，不能把整个列表弄失败。
        var listing = CodexListing()
        listing.headerBatching.files = 1
        let source = CodexHistorySource(provider: sftp, home: home, listing: listing)
        let projects = try await source.projects()
        XCTAssertEqual(Set(projects.map(\.id)), [quotedCwd, F.cwd, CodexZstdFixture.cwd])
        let canExecute = await source.canExecute
        XCTAssertEqual(canExecute, false)
        do {
            _ = try await search(source, "mixed")
            XCTFail("跑不了命令也搜了")
        } catch {
            XCTAssertEqual(error as? AgentHistorySearchError, .cannotExecute)
        }
    }
}
