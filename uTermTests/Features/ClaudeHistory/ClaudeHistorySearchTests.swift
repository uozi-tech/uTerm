import XCTest
@testable import uTerm

/// 搜索要用的手写假数据：一台主机上的几份记录。内容全是编的。
enum ClaudeSearchFixture {
    static let home = "/home/user"
    static let root = "/home/user/.claude/projects"
    static let directory = "/home/user/projects/demo"
    static var project: String { ClaudeProjectPath.encode(directory) }

    static func sessionID(_ index: Int) -> String { String(format: "%08x-1111-4222-8333-%012x", index, index) }

    static func path(_ index: Int, project: String = project) -> String { "\(root)/\(project)/\(sessionID(index)).jsonl" }

    /// 在 `MockSFTP` 里摆好：`sessions` 是（编号、内容、多久以前），项目目录可以有几个。
    static func host(_ sessions: [(index: Int, data: Data, age: TimeInterval, project: String)],
                     extraEntries: [String: [RemoteEntry]] = [:]) async -> MockSFTP {
        let now = Date()
        let projects = Set(sessions.map(\.project))
        var tree: [String: [RemoteEntry]] = [root: projects.sorted().map { ClaudeFixture.entry($0, directory: true, mtime: now) }]
        for project in projects {
            tree["\(root)/\(project)"] = sessions.filter { $0.project == project }.map {
                ClaudeFixture.entry("\(sessionID($0.index)).jsonl", size: UInt64($0.data.count), mtime: now.addingTimeInterval(-$0.age))
            }
        }
        tree.merge(extraEntries) { $0 + $1 }
        let sftp = MockSFTP(tree: tree)
        for session in sessions {
            await sftp.setFile(path(session.index, project: session.project), data: session.data,
                               mtime: now.addingTimeInterval(-session.age))
        }
        await sftp.answersClaudeSearch()
        return sftp
    }

    static func session(_ lines: [String], title: String) -> Data {
        ClaudeFixture.file(lines + [ClaudeFixture.aiTitle(title)])
    }

    /// 含引号、反斜杠、`$`、反引号、`*`、开头是 `-`、空格、中文、`!`、`%`……的搜索词。每个都放进一句用户的话里。
    static let nastyTerms = [
        "it's mine", #"say "hi" now"#, #"C:\temp\new"#, "$HOME and $(whoami)", "`uname -a`", "*.swift files",
        "-rf --force", "two  spaces", "中文搜索词", "!history", "%s %d %%", #"\c stop"#, "semi;colon|pipe&amp>out<in",
        "{braces} [brackets] (parens)", "tab\\tnot", "~/tilde #hash",
    ]
}

/// 命令怎么拼、怎么解：搜索词与路径不能把命令弄坏，也不能注入。
final class ClaudeSearchCommandTests: XCTestCase {
    func testEncodedWordsOnlyContainSafeCharacters() {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/,:=+@-")
        for term in ClaudeSearchFixture.nastyTerms {
            let word = ClaudeSearchCommand.encodedWord(term)
            XCTAssertTrue(word.hasPrefix("'") && word.hasSuffix("'"), term)
            let inner = Array(word.dropFirst().dropLast())
            var index = 0
            while index < inner.count {
                if inner[index] == "\\" {
                    // 只有「反斜杠 0 三位八进制」：fish 的单引号里只认 `\\` 与 `\'`，这两种都不会出现。
                    XCTAssertTrue(index + 4 < inner.count, term)
                    XCTAssertEqual(inner[index + 1], "0", term)
                    XCTAssertTrue(inner[(index + 2)...(index + 4)].allSatisfy { "01234567".contains($0) }, term)
                    index += 5
                } else {
                    XCTAssertTrue(safe.contains(inner[index]), "\(term) 里的 \(inner[index]) 没编码")
                    index += 1
                }
            }
        }
    }

    func testCommandRoundTripsThroughDecode() {
        for term in ClaudeSearchFixture.nastyTerms {
            let needle = ClaudeSearchCommand.jsonEscaped(term)
            let names = ["./-home-user-it's dir/a.jsonl", "./-x/\(ClaudeSearchFixture.sessionID(1)).jsonl"]
            let files = ClaudeSearchCommand.filesContaining(needle, root: "/home/us er/.claude/projects", names: names)
            XCTAssertEqual(ClaudeSearchCommand.decode(files),
                           .files(needle: needle, root: "/home/us er/.claude/projects", names: names), term)
            let lines = ClaudeSearchCommand.matchingLines(needle, root: "/r", maxLines: 30, maxLineBytes: 1024, names: names)
            XCTAssertEqual(ClaudeSearchCommand.decode(lines),
                           .lines(needle: needle, root: "/r", maxLines: 30, maxLineBytes: 1024, names: names), term)
            // 发出去的整串：启动器之后只有单引号括起来的编码字，没有换行。
            XCTAssertFalse(files.contains("\n"))
            XCTAssertTrue(files.hasPrefix(#"sh -c 'eval "$(printf %b "$1")"' sh '"#))
        }
        XCTAssertNil(ClaudeSearchCommand.decode("rm -rf /"))
    }

    func testJSONEscapingMatchesHowRecordsAreWritten() {
        XCTAssertEqual(ClaudeSearchCommand.jsonEscaped(#"say "hi" C:\temp"#), #"say \"hi\" C:\\temp"#)
        XCTAssertEqual(ClaudeSearchCommand.jsonEscaped("中文 / path"), "中文 / path", "中文与 / 原样")
        // 和记录里实际写出来的一致（JSON 字符串里的那一段）。
        for term in ClaudeSearchFixture.nastyTerms {
            let encoded = ClaudeFixture.json("前 \(term) 后")
            XCTAssertTrue(encoded.contains(ClaudeSearchCommand.jsonEscaped(term)), term)
        }
    }

    func testPayloadSkipsLoginNoiseAndReadsStatus() throws {
        let output = "Welcome to the host\nuterm-claude-search:begin\n./a.jsonl\n\n./b.jsonl\nuterm-claude-search:end 0\n"
        let payload = try ClaudeSearchCommand.payload(of: output)
        XCTAssertEqual(payload.lines, ["./a.jsonl", "./b.jsonl"])
        XCTAssertEqual(payload.status, 0)
        XCTAssertEqual(try ClaudeSearchCommand.payload(of: "uterm-claude-search:begin\r\n./a\r\nuterm-claude-search:end 1\r\n").lines,
                       ["./a"])

        XCTAssertThrowsError(try ClaudeSearchCommand.payload(of: "This service allows sftp connections only.\n")) {
            XCTAssertEqual($0 as? AgentHistorySearchError, .cannotExecute)
        }
        XCTAssertThrowsError(try ClaudeSearchCommand.payload(of: "uterm-claude-search:begin\n./a.jsonl\n")) {
            XCTAssertEqual($0 as? AgentHistorySearchError, .incompleteOutput)
        }
        XCTAssertThrowsError(try ClaudeSearchCommand.payload(of: "uterm-claude-search:begin\nuterm-claude-search:end 127\n")) {
            XCTAssertEqual($0 as? AgentHistorySearchError, .missingTools)
        }
    }

    func testLineReferencesIgnoreGarbage() {
        let refs = ClaudeSearchCommand.lineReferences(["1 0 120", "2 4096 33", "x 1 2", "3 -1 4", "0 5 6", "4 5"])
        XCTAssertEqual(refs.map(\.file), [1, 2])
        XCTAssertEqual(refs.map(\.offset), [0, 4096])
        XCTAssertEqual(refs.map(\.length), [120, 33])
    }

    func testBatchesKeepOrderAndRespectBudgets() {
        let batching = ClaudeSearchBatching(files: 3, nameBytes: 40, bytes: 100, linesFiles: 2)
        let items: [(name: String, size: UInt64)] = (0..<8).map { ("./p/\($0).jsonl", $0 == 5 ? 500 : 10) }
        let batches = batching.batches(items, name: \.name, size: \.size)
        XCTAssertEqual(batches.flatMap { $0 }.map(\.name), items.map(\.name), "不打乱、不漏")
        XCTAssertTrue(batches.allSatisfy { $0.count <= 3 })
        XCTAssertTrue(batches.contains { $0.count == 1 && $0[0].size == 500 }, "一份就超了大小上限的自成一批")
    }

    func testLineBoundaryCheck() {
        let data = Data("x\n{\"a\":1}\r\nzz".utf8)
        XCTAssertEqual(ClaudeHistorySource.line(at: 2, length: 8, in: data.subdata(in: 1..<12), from: 1),
                       Data("{\"a\":1}".utf8), "CR 去掉")
        XCTAssertNil(ClaudeHistorySource.line(at: 3, length: 7, in: data.subdata(in: 2..<11), from: 2), "前面不是换行")
        XCTAssertNil(ClaudeHistorySource.line(at: 2, length: 4, in: data.subdata(in: 1..<8), from: 1), "后面不是换行")
    }
}

/// 哪些文字参与搜索、截前后文。
final class AgentHistorySearchMatcherTests: XCTestCase {
    private func query(_ text: String) -> AgentHistorySearchQuery {
        try! AgentHistorySearchQuery.validate(text).get()
    }

    private func items(_ line: String) -> [AgentTranscriptItem] {
        ClaudeTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: "100")
    }

    func testSearchesUserTextAnswersAndToolSummariesOnly() {
        XCTAssertEqual(AgentHistorySearchMatcher.firstHit(in: items(ClaudeFixture.userText("帮我查 Deadline 的原因")),
                                                          query: query("deadline"))?.item.role, .user)
        XCTAssertEqual(AgentHistorySearchMatcher.firstHit(
            in: items(ClaudeFixture.assistant(ClaudeFixture.textBlock("连接池太小了"))), query: query("连接池"))?.item.role,
            .assistant)
        let call = ClaudeFixture.assistant(ClaudeFixture.toolUse(id: "t1", name: "Bash", input: #"{"command":"go test ./auth/..."}"#))
        let hit = AgentHistorySearchMatcher.firstHit(in: items(call), query: query("go test"))
        XCTAssertEqual(hit?.item.id, "100.0")
        XCTAssertEqual(hit?.snippet.plain, "Bash go test ./auth/...")
        XCTAssertNotNil(AgentHistorySearchMatcher.firstHit(in: items(call), query: query("bash")), "工具名也算")

        // 思考、工具结果、压缩摘要不搜。
        XCTAssertNil(AgentHistorySearchMatcher.firstHit(
            in: items(ClaudeFixture.assistant(ClaudeFixture.thinkingBlock("想想 deadline"))), query: query("deadline")))
        XCTAssertNil(AgentHistorySearchMatcher.firstHit(
            in: items(ClaudeFixture.toolResult(id: "t1", text: "context deadline exceeded")), query: query("deadline")))
        XCTAssertNil(AgentHistorySearchMatcher.firstHit(
            in: items(ClaudeFixture.user(content: ClaudeFixture.json("摘要：deadline"), flags: #","isCompactSummary":true"#)),
            query: query("deadline")))
        // 系统注入的部分去掉之后才搜。
        XCTAssertNil(AgentHistorySearchMatcher.firstHit(
            in: items(ClaudeFixture.userText("<system-reminder>deadline</system-reminder>你好")), query: query("deadline")))
    }

    func testCaseFoldsOnlyASCIIAndMatchesChineseAsIs() {
        let text = "Hello WORLD，你好世界，Straße"
        XCTAssertEqual(AgentHistorySearchMatcher.snippet(of: "hello world", in: text)?.match, "Hello WORLD")
        XCTAssertEqual(AgentHistorySearchMatcher.snippet(of: "好世", in: text)?.match, "好世")
        XCTAssertNil(AgentHistorySearchMatcher.snippet(of: "STRASSE", in: text))
        XCTAssertNil(AgentHistorySearchMatcher.snippet(of: "你好 世界", in: text))
    }

    func testSnippetKeepsSomeContextAndMarksClipping() throws {
        let long = String(repeating: "前面的字", count: 30) + "\n命中的词\n" + String(repeating: "后面的字", count: 60)
        let snippet = try XCTUnwrap(AgentHistorySearchMatcher.snippet(of: "命中的词", in: long))
        XCTAssertEqual(snippet.match, "命中的词")
        XCTAssertTrue(snippet.before.hasPrefix("…"))
        XCTAssertTrue(snippet.before.hasSuffix(" "), "换行折成空格")
        XCTAssertTrue(snippet.after.hasSuffix("…"))
        XCTAssertLessThanOrEqual(snippet.before.count, AgentHistorySearchMatcher.contextBefore + 1)
        XCTAssertLessThanOrEqual(snippet.after.count, AgentHistorySearchMatcher.contextAfter + 1)

        let short = try XCTUnwrap(AgentHistorySearchMatcher.snippet(of: "deadline", in: "context deadline exceeded"))
        XCTAssertEqual(short, AgentHistorySnippet(before: "context ", match: "deadline", after: " exceeded"))
    }

    func testQueryValidation() {
        XCTAssertEqual(AgentHistorySearchQuery.validate("  ab  "), .success(try! AgentHistorySearchQuery.validate("ab").get()))
        XCTAssertEqual(try? AgentHistorySearchQuery.validate("  中文  ").get().text, "中文")
        XCTAssertEqual(AgentHistorySearchQuery.validate("a"), .failure(.tooShort))
        XCTAssertEqual(AgentHistorySearchQuery.validate("   "), .failure(.tooShort))
        XCTAssertEqual(AgentHistorySearchQuery.validate(String(repeating: "字", count: 201)), .failure(.tooLong))
        XCTAssertNotNil(try? AgentHistorySearchQuery.validate(String(repeating: "字", count: 200)).get())
        XCTAssertEqual(AgentHistorySearchQuery.validate("ab\ncd"), .failure(.controlCharacters))
        XCTAssertEqual(AgentHistorySearchQuery.validate("ab\u{0}cd"), .failure(.controlCharacters))
        XCTAssertEqual(AgentHistorySearchQuery.validate("ab\tcd"), .failure(.controlCharacters))
        XCTAssertEqual(AgentHistorySearchQuery.validate("ab\u{2028}cd"), .failure(.controlCharacters))
    }
}

/// 两段式搜索走一遍（假主机照命令的意思答，见 `ClaudeSearchHostEmulator`）。
@MainActor
final class ClaudeHistorySearchSourceTests: XCTestCase {
    private typealias F = ClaudeSearchFixture

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentHistorySearchEvent] = []
        var events: [AgentHistorySearchEvent] { lock.withLock { stored } }
        func append(_ event: AgentHistorySearchEvent) { lock.withLock { stored.append(event) } }
        var sessions: [AgentHistorySearchSession] {
            events.compactMap { if case .session(let session) = $0 { return session } else { return nil } }
        }
    }

    private func run(_ source: ClaudeHistorySource, _ text: String, limits: AgentHistorySearchLimits = .standard)
        async throws -> Recorder {
        let recorder = Recorder()
        let projects = try await source.projects()
        let files = await source.allSessions(in: projects)
        try await source.search(try AgentHistorySearchQuery.validate(text).get(), in: files, limits: limits) { event in
            recorder.append(event)
        }
        return recorder
    }

    private func standardHost() async -> MockSFTP {
        await F.host([
            (1, F.session([
                ClaudeFixture.userText("登录接口偶尔返回 500，日志里是 context deadline exceeded。"),
                ClaudeFixture.assistant(ClaudeFixture.thinkingBlock("deadline 可能是连接池")),
                ClaudeFixture.assistant(ClaudeFixture.toolUse(id: "t1", name: "Bash", input: #"{"command":"grep -rn Deadline ./internal"}"#)),
                ClaudeFixture.toolResult(id: "t1", text: "internal/db.go:12: deadline := 2 * time.Second"),
                ClaudeFixture.assistant(ClaudeFixture.textBlock("原因是连接池太小，排队超过 DEADLINE。")),
            ], title: "登录超时"), 60, F.project),
            // 只在工具结果与思考里出现：不算。
            (2, F.session([
                ClaudeFixture.userText("看看日志"),
                ClaudeFixture.assistant(ClaudeFixture.thinkingBlock("要找 deadline")),
                ClaudeFixture.toolResult(id: "t2", text: "context deadline exceeded"),
            ], title: "看日志"), 120, F.project),
            // 桌面版起的：不列，也不出现在结果里。
            (3, F.session([ClaudeFixture.userText("桌面版也问了 deadline", entrypoint: "claude-desktop")], title: "桌面版"),
             30, F.project),
            // 另一个项目里更早的一份。
            (4, F.session([ClaudeFixture.userText("另一个项目的 deadline 问题")], title: "别的项目"), 600, "-home-user-other"),
        ])
    }

    func testFindsHitsOnlyInDisplayableTextOfListedSessionsNewestFirst() async throws {
        let sftp = await standardHost()
        let recorder = try await run(ClaudeHistorySource(provider: sftp), "deadline")
        let sessions = recorder.sessions
        XCTAssertEqual(sessions.map(\.file.sessionID), [F.sessionID(1), F.sessionID(4)], "新的在前；桌面版与只在工具结果里的不出")
        let first = try XCTUnwrap(sessions.first)
        XCTAssertEqual(first.metadata.title, "登录超时")
        XCTAssertEqual(first.hits.map(\.role), [.user, .assistant, .assistant], "用户的话、工具调用、回答；思考与工具结果不算")
        XCTAssertEqual(first.hits.map(\.snippet.match), ["deadline", "Deadline", "DEADLINE"])
        XCTAssertEqual(first.hits[1].snippet.plain, "Bash grep -rn Deadline ./internal")
        XCTAssertEqual(recorder.events.last, .finished(truncated: false))
        if case .progress(let searched, let total) = recorder.events.dropLast().last {
            XCTAssertEqual(searched, total)
            XCTAssertEqual(total, 4)
        } else {
            XCTFail("最后报一次进度")
        }

        // 条目 ID、行的位置与打开对话后读到的一致。
        let stored = await sftp.fileData(F.path(1))
        let data = try XCTUnwrap(stored)
        for hit in first.hits {
            let line = data.subdata(in: Int(hit.anchor.lineOffset)..<(Int(hit.anchor.lineOffset) + hit.anchor.lineLength))
            XCTAssertEqual(ClaudeTranscriptParser.items(fromJSON: line, idPrefix: String(hit.anchor.lineOffset))
                .contains { $0.id == hit.itemID }, true)
        }
    }

    func testEveryNastyTermIsFoundIntact() async throws {
        var lines: [String] = []
        for (index, term) in F.nastyTerms.enumerated() {
            lines.append(ClaudeFixture.userText("第 \(index) 句：\(term) 结束", uuid: "u-\(index)"))
        }
        let sftp = await F.host([(1, F.session(lines, title: "怪字符"), 60, F.project),
                                 (2, F.session([ClaudeFixture.userText("没有那些字")], title: "别的"), 120, F.project)])
        let source = ClaudeHistorySource(provider: sftp)
        for term in F.nastyTerms {
            let recorder = try await run(source, term)
            XCTAssertEqual(recorder.sessions.map(\.file.sessionID), [F.sessionID(1)], term)
            XCTAssertEqual(recorder.sessions.first?.hits.first?.snippet.match, term.trimmingCharacters(in: .whitespaces), term)
        }
    }

    func testDoesNotSearchSubagentRecords() async throws {
        let session = F.sessionID(1)
        let subagents = "\(F.root)/\(F.project)/\(session)/subagents"
        let sftp = await F.host([(1, F.session([ClaudeFixture.userText("主对话")], title: "主"), 60, F.project)],
                                extraEntries: [subagents: [ClaudeFixture.entry("agent-a1.jsonl", size: 10)]])
        await sftp.setFile("\(subagents)/agent-a1.jsonl",
                           data: ClaudeFixture.file([ClaudeFixture.sidechainUser("子代理里的 needle", agentID: "a1")]), mtime: Date())
        let source = ClaudeHistorySource(provider: sftp)
        // 就算有人把子代理的记录交进来，也不搜。
        let projects = try await source.projects()
        var files = await source.allSessions(in: projects)
        files.append(AgentHistorySessionFile(sessionID: "agent-a1", project: files[0].project,
                                             path: "\(subagents)/agent-a1.jsonl", size: 10, modifiedAt: Date()))
        let recorder = Recorder()
        try await source.search(try AgentHistorySearchQuery.validate("needle").get(), in: files, limits: .standard) {
            recorder.append($0)
        }
        XCTAssertEqual(recorder.sessions, [])
        let names = await sftp.execCommands.compactMap(ClaudeSearchCommand.decode).flatMap { request -> [String] in
            if case .files(_, _, let names) = request { return names } else { return [] }
        }
        XCTAssertEqual(names, ["./\(F.project)/\(session).jsonl"])
    }

    func testLimitsStopSendingCommandsAndMarkTruncation() async throws {
        var sessions: [(index: Int, data: Data, age: TimeInterval, project: String)] = []
        for index in 1...6 {
            let lines = (0..<4).map { ClaudeFixture.userText("第 \($0) 次提到 needle", uuid: "u-\(index)-\($0)") }
            sessions.append((index, F.session(lines, title: "会话 \(index)"), TimeInterval(index * 60), F.project))
        }
        let sftp = await F.host(sessions)
        let source = ClaudeHistorySource(provider: sftp, searchBatching: ClaudeSearchBatching(files: 2, linesFiles: 1))
        let limits = AgentHistorySearchLimits(totalHits: 5, hitsPerSession: 3, candidateLinesPerSession: 30, maxLineBytes: 1 << 20)
        let recorder = try await run(source, "NEEDLE", limits: limits)
        XCTAssertEqual(recorder.sessions.map(\.hits.count), [3, 2])
        XCTAssertEqual(recorder.sessions.map(\.hasMoreHits), [true, true])
        XCTAssertEqual(recorder.events.last, .finished(truncated: true))
        // 到了上限就不再发命令：第一批两份（第一段一条 + 第二段两条），第二批没发。
        let commands = await sftp.execCommands.compactMap(ClaudeSearchCommand.decode)
        XCTAssertEqual(commands.count, 3)
    }

    func testHostThatCannotRunCommands() async throws {
        let sftp = await standardHost()
        await sftp.setExecHandler { _ in "This service allows sftp connections only.\n" }
        do {
            _ = try await run(ClaudeHistorySource(provider: sftp), "deadline")
            XCTFail("应当报跑不了命令")
        } catch {
            XCTAssertEqual(error as? AgentHistorySearchError, .cannotExecute)
        }
        struct ChannelFailed: Error {}
        await sftp.setExecHandler { _ in throw ChannelFailed() }
        do {
            _ = try await run(ClaudeHistorySource(provider: sftp), "deadline")
            XCTFail("应当报跑不了命令")
        } catch {
            XCTAssertEqual(error as? AgentHistorySearchError, .cannotExecute, "连接还在、只是 exec 不行")
        }
        XCTAssertEqual(AgentHistoryText.searchFailure(AgentHistorySearchError.cannotExecute), "这台主机不能执行命令，无法搜索")
    }

    func testCancellationStopsFurtherCommands() async throws {
        var sessions: [(index: Int, data: Data, age: TimeInterval, project: String)] = []
        for index in 1...10 {
            sessions.append((index, F.session([ClaudeFixture.userText("needle \(index)")], title: "会话"), TimeInterval(index), F.project))
        }
        let sftp = await F.host(sessions)
        await sftp.setBlockExec(true)
        let source = ClaudeHistorySource(provider: sftp, searchBatching: ClaudeSearchBatching(files: 2))
        let projects = try await source.projects()
        let files = await source.allSessions(in: projects)
        let task = Task {
            try await source.search(try AgentHistorySearchQuery.validate("needle").get(), in: files, limits: .standard) { _ in }
        }
        for _ in 0..<200 where !(await sftp.didStartExec()) { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await sftp.releaseExec()
        _ = await task.result
        let count = await sftp.execCommands.count
        XCTAssertEqual(count, 1, "取消之后不再发后面的命令")
    }
}

/// 列表模型里的搜索：按回车才搜、改词丢掉旧结果、范围跟着项目走、点命中定位。
@MainActor
final class AgentHistorySearchModelTests: XCTestCase {
    private typealias F = ClaudeSearchFixture

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func model(_ sftp: MockSFTP, directory: String? = nil, allowsSearch: Bool = true) async -> AgentHistoryModel {
        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: sftp), preferredDirectory: directory,
                                      allowsSearch: allowsSearch)
        await model.start()
        return model
    }

    private func host() async -> MockSFTP {
        var lines = [ClaudeFixture.userText("第一个问题：needle 在哪", uuid: "u-0")]
        for turn in 1...60 {
            lines.append(ClaudeFixture.userText("第 \(turn) 个问题", uuid: "u-\(turn)"))
            lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("第 \(turn) 个回答"), uuid: "a-\(turn)"))
        }
        lines.append(ClaudeFixture.userText("最后又说到 needle", uuid: "u-last"))
        return await F.host([
            (1, F.session(lines, title: "很长的对话"), 60, F.project),
            (2, F.session([ClaudeFixture.userText("别的项目的 needle")], title: "别的项目"), 120, "-home-user-other"),
        ])
    }

    func testSearchesOnSubmitAndDropsResultsWhenTheTextChanges() async throws {
        let sftp = await host()
        let model = await model(sftp)
        model.searchText = "needle"
        XCTAssertNil(model.search, "打字时不搜")
        let before = await sftp.execCommands.count
        XCTAssertEqual(before, 0)

        model.submitSearch()
        await waitUntil { model.search?.phase == .finished }
        XCTAssertEqual(model.search?.sessions.map(\.file.sessionID), [F.sessionID(1), F.sessionID(2)])
        XCTAssertEqual(model.search?.hitCount, 3)

        model.searchText = "needle "
        XCTAssertNotNil(model.search, "只多了空白：还是同一个词")
        model.searchText = "needles"
        XCTAssertNil(model.search, "改了词：旧结果丢掉，回到列表")
        model.searchText = "x"
        model.submitSearch()
        XCTAssertEqual(model.searchProblem, .tooShort)
        XCTAssertNil(model.search)
        model.searchText = "needle"
        model.submitSearch()
        await waitUntil { model.search?.phase == .finished }
        model.clearSearch()
        XCTAssertNil(model.search)
        XCTAssertEqual(model.searchText, "")
    }

    func testStaleResultsFromAnOldSearchAreDropped() async throws {
        let sftp = await host()
        let model = await model(sftp)
        await sftp.setBlockExec(true)
        model.searchText = "needle"
        model.submitSearch()
        for _ in 0..<200 where !(await sftp.didStartExec()) { try await Task.sleep(for: .milliseconds(5)) }
        // 旧搜索的命令还没回来就换了词搜。
        model.searchText = "第一个问题"
        model.submitSearch()
        await sftp.releaseExec()
        await sftp.setBlockExec(false)
        await waitUntil { model.search?.phase == .finished }
        XCTAssertEqual(model.search?.query.text, "第一个问题")
        XCTAssertEqual(model.search?.sessions.flatMap(\.hits).map(\.snippet.match), ["第一个问题"])
    }

    func testScopeFollowsTheProjectPicker() async throws {
        let sftp = await host()
        let model = await model(sftp, directory: F.directory)
        XCTAssertEqual(model.scope, .project(try XCTUnwrap(model.currentProject)))
        model.searchText = "needle"
        model.submitSearch()
        await waitUntil { model.search?.phase == .finished }
        XCTAssertEqual(model.search?.sessions.map(\.file.sessionID), [F.sessionID(1)], "只搜当前项目")
        await model.setScope(.all)
        await waitUntil { model.search?.phase == .finished && model.search?.sessions.count == 2 }
        XCTAssertEqual(model.search?.sessions.map(\.file.sessionID), [F.sessionID(1), F.sessionID(2)], "全部项目时搜全部")
    }

    func testStopKeepsWhatWasFound() async throws {
        let sftp = await host()
        let model = await model(sftp)
        await sftp.setBlockExec(true)
        model.searchText = "needle"
        model.submitSearch()
        XCTAssertTrue(model.search?.isRunning == true)
        model.stopSearch()
        XCTAssertEqual(model.search?.phase, .stopped)
        await sftp.releaseExec()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.search?.phase, .stopped, "停了之后回来的结果不再接")
    }

    func testHostMarkedSFTPOnlyDoesNotSearch() async throws {
        let sftp = await host()
        let model = await model(sftp, allowsSearch: false)
        model.searchText = "needle"
        model.submitSearch()
        XCTAssertEqual(model.search?.phase, .failed("这台主机不能执行命令，无法搜索"))
        let commands = await sftp.execCommands
        XCTAssertEqual(commands, [])
        // 别的功能照常。
        await waitUntil { !model.hasMore }
        XCTAssertFalse(model.visibleFiles.isEmpty)
    }

    func testOpeningAHitLandsOnItWithoutReadingTheWholeFile() async throws {
        let sftp = await host()
        let model = await model(sftp)
        model.searchText = "needle"
        model.submitSearch()
        await waitUntil { model.search?.phase == .finished }
        let session = try XCTUnwrap(model.search?.sessions.first)
        let hit = try XCTUnwrap(session.hits.first)
        XCTAssertEqual(hit.snippet.match, "needle")
        await sftp.clearRangeReads()

        model.openHit(hit, in: session)
        let transcript = try XCTUnwrap(model.transcript)
        await waitUntil { !transcript.items.isEmpty }
        XCTAssertEqual(transcript.highlightedItemID, hit.itemID)
        XCTAssertEqual(transcript.items.last?.id, hit.itemID, "第一页到命中那一条为止")
        XCTAssertTrue(transcript.reachedStart)
        XCTAssertFalse(transcript.reachedEnd)
        XCTAssertEqual(transcript.focusGeneration, 1)
        XCTAssertTrue(transcript.opensAtHit)
        let read = await sftp.rangeReads.reduce(0) { $0 + $1.length }
        XCTAssertLessThan(read, 4096, "只读了命中那一行和它前面的")

        // 再点同一条：已经读进来了，只是滚过去。
        model.openHit(hit, in: session)
        XCTAssertTrue(model.transcript === transcript)
        XCTAssertEqual(transcript.focusGeneration, 2)

        // 跳到最新：换成从末尾打开的。
        model.jumpToLatest()
        let latest = try XCTUnwrap(model.transcript)
        XCTAssertFalse(latest === transcript)
        await waitUntil { !latest.items.isEmpty }
        XCTAssertTrue(latest.reachedEnd)
        XCTAssertNil(latest.highlightedItemID)
        XCTAssertEqual(latest.items.last?.plainText, "最后又说到 needle")
    }
}

/// 从某一行打开的分页：前一页、往后一页页读、到末尾后接上跟随、ID 与从末尾读一致、不整份读。
final class ClaudeTranscriptAnchorPagerTests: XCTestCase {
    private let path = "/home/user/.claude/projects/-p/x.jsonl"

    private func fixture(turns: Int) -> (data: Data, offsets: [UInt64]) {
        var lines: [String] = []
        for turn in 0..<turns {
            lines.append(ClaudeFixture.userText("问题 \(turn)", uuid: "u-\(turn)"))
            lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("回答 \(turn)"), uuid: "a-\(turn)"))
        }
        var offsets: [UInt64] = []
        var offset: UInt64 = 0
        for line in lines {
            offsets.append(offset)
            offset += UInt64(line.utf8.count + 1)
        }
        return (ClaudeFixture.file(lines), offsets)
    }

    private func allItemsFromEnd(_ sftp: MockSFTP) async throws -> [AgentTranscriptItem] {
        let pager = ClaudeTranscriptPager(provider: sftp, path: path, chunkBytes: 4096, pageItems: 10)
        var items: [AgentTranscriptItem] = []
        while true {
            let page = try await pager.loadPrevious()
            items = page.items + items
            if page.reachedStart { return items }
        }
    }

    func testOpensAroundTheAnchorAndPagesForward() async throws {
        let (data, offsets) = fixture(turns: 200)
        let sftp = MockSFTP()
        await sftp.setFile(path, data: data, mtime: Date())
        let anchorIndex = 101   // 「回答 50」
        let anchor = AgentTranscriptAnchor(lineOffset: offsets[anchorIndex],
                                           lineLength: Int(offsets[anchorIndex + 1] - offsets[anchorIndex]) - 1)
        let pager = ClaudeTranscriptPager(provider: sftp, path: path, anchor: anchor, chunkBytes: 4096, pageItems: 10,
                                          pageBytes: 1 << 20)
        let first = try await pager.loadPrevious()
        XCTAssertEqual(first.items.last?.id, "\(offsets[anchorIndex]).0", "第一页以命中那一行结束")
        XCTAssertEqual(first.items.last?.plainText, "回答 50")
        XCTAssertFalse(first.reachedStart)
        let read = await sftp.rangeReads.reduce(0) { $0 + $1.length }
        XCTAssertLessThan(read, data.count / 4, "没有整份读")
        let early = try await pager.loadNewer()
        XCTAssertEqual(early, .unchanged, "往后还没读到末尾：不跟")

        // 往后一页页读，直到末尾。
        var later: [AgentTranscriptItem] = []
        var pages = 0
        while true {
            let growth = try await pager.loadNext()
            guard case .appended(let items, let hasMore) = growth else { return XCTFail("应当读到东西") }
            later += items
            pages += 1
            XCTAssertLessThanOrEqual(items.count, 25)
            if !hasMore { break }
        }
        XCTAssertGreaterThan(pages, 5, "一页一页地读")
        XCTAssertEqual(later.first?.plainText, "问题 51")
        XCTAssertEqual(later.last?.plainText, "回答 199")
        let after = try await pager.loadNext()
        XCTAssertEqual(after, .unchanged)

        // 往前翻完，和从末尾读的整份逐条一致（ID 也一样）。
        var earlier = first.items
        var reachedStart = first.reachedStart
        while !reachedStart {
            let page = try await pager.loadPrevious()
            earlier = page.items + earlier
            reachedStart = page.reachedStart
        }
        let fromEnd = try await allItemsFromEnd(sftp)
        XCTAssertEqual((earlier + later).map(\.id), fromEnd.map(\.id))
        XCTAssertEqual(earlier + later, fromEnd)

        // 读到末尾之后接上跟随。
        var grown = data
        grown.append(Data((ClaudeFixture.userText("新来的", uuid: "u-new") + "\n").utf8))
        await sftp.setFile(path, data: grown, mtime: Date())
        guard case .appended(let appended, _) = try await pager.loadNewer() else { return XCTFail("应当接上新内容") }
        XCTAssertEqual(appended.map(\.plainText), ["新来的"])
        XCTAssertEqual(appended.first?.id, "\(data.count).0")
    }

    func testFileReplacedWhilePagingForwardStartsOverFromTheEnd() async throws {
        let (data, offsets) = fixture(turns: 50)
        let sftp = MockSFTP()
        await sftp.setFile(path, data: data, mtime: Date())
        let anchor = AgentTranscriptAnchor(lineOffset: offsets[40], lineLength: Int(offsets[41] - offsets[40]) - 1)
        let pager = ClaudeTranscriptPager(provider: sftp, path: path, anchor: anchor, pageItems: 10)
        _ = try await pager.loadPrevious()
        await sftp.setFile(path, data: data.prefix(100), mtime: Date())
        let replaced = try await pager.loadNext()
        XCTAssertEqual(replaced, .replaced)
        let again = try await pager.loadPrevious()
        XCTAssertTrue(again.reachedStart, "换成了从末尾读那份短的")
    }

    func testFromEndPagerNeverPagesForward() async throws {
        let (data, _) = fixture(turns: 3)
        let sftp = MockSFTP()
        await sftp.setFile(path, data: data, mtime: Date())
        let pager = ClaudeTranscriptPager(provider: sftp, path: path)
        _ = try await pager.loadPrevious()
        let next = try await pager.loadNext()
        XCTAssertEqual(next, .unchanged)
    }
}
