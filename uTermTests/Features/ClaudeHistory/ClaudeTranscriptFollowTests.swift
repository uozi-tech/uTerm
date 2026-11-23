import Synchronization
import XCTest
@testable import uTerm

/// 往后切行：最后一行没写完先攒着，跨块的行拼好，超长的只留行首。
final class ClaudeForwardLineScannerTests: XCTestCase {
    private func text(_ lines: [ClaudeForwardLineScanner.Line]) -> [String] {
        lines.map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    func testSplitsLinesAndHoldsTheUnfinishedOne() {
        var scanner = ClaudeForwardLineScanner(position: 100)
        let first = scanner.feed(Data("ab\ncd\nef".utf8))
        XCTAssertEqual(text(first), ["ab", "cd"])
        XCTAssertEqual(first.map(\.offset), [100, 103])
        XCTAssertEqual(scanner.position, 108)
        XCTAssertTrue(scanner.hasPartialLine)

        let second = scanner.feed(Data("gh\r\n\nij\n".utf8))
        XCTAssertEqual(text(second), ["efgh", "ij"], "跨块的行拼好，CR 去掉，空行跳过")
        XCTAssertEqual(second.map(\.offset), [106, 113])
        XCTAssertEqual(second.first?.length, 5)
        XCTAssertFalse(scanner.hasPartialLine)
    }

    func testOversizedLineKeepsOnlyItsHead() {
        var scanner = ClaudeForwardLineScanner(position: 0, maxLineBytes: 8, headBytes: 4)
        _ = scanner.feed(Data("0123456".utf8))
        let lines = scanner.feed(Data("789abc\nok\n".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].isTruncated)
        XCTAssertEqual(lines[0].length, 13)
        XCTAssertEqual(String(decoding: lines[0].bytes, as: UTF8.self), "0123")
        XCTAssertEqual(text([lines[1]]), ["ok"])
        XCTAssertEqual(lines[1].offset, 14)
    }

    func testStartingMidLineDropsUntilTheFirstNewline() {
        var scanner = ClaudeForwardLineScanner(position: 50, startsMidLine: true)
        XCTAssertEqual(scanner.feed(Data("tail of a line".utf8)), [])
        let lines = scanner.feed(Data(" end\nnext\n".utf8))
        XCTAssertEqual(text(lines), ["next"])
        XCTAssertEqual(lines.first?.offset, 69)
    }
}

/// 可控的时钟与「睡」：不真的睡好几秒。
final class FollowClock: Sendable {
    private let offset = Mutex<Duration>(.zero)
    private let sleeps = Mutex<[Duration]>([])
    private let base = ContinuousClock.now

    func advance(_ by: Duration) { offset.withLock { $0 += by } }
    var requestedSleeps: [Duration] { sleeps.withLock { $0 } }

    /// `interval` 照给（只是记下来），真睡的只有 `realSleep`。
    func timing(interval: Duration = .seconds(2), realSleep: Duration = .milliseconds(5),
                relist: Duration = .zero) -> AgentTranscriptFollowTiming {
        AgentTranscriptFollowTiming(
            interval: interval, maxBackoff: .seconds(30), activeWindow: .seconds(60), subagentRelist: relist,
            sleep: { [self] duration in
                sleeps.withLock { $0.append(duration) }
                try await Task.sleep(for: realSleep)
            },
            now: { [self] in base + offset.withLock { $0 } })
    }
}

/// 实时跟随：打开着的对话，文件变长了把新内容接上来。全用 `MockSFTP` 与手写的假记录。
@MainActor
final class ClaudeTranscriptFollowTests: XCTestCase {
    private let root = "/home/user/.claude/projects"
    private let project = "-home-user-projects-demo"
    private var path: String { "\(root)/\(project)/\(ClaudeFixture.sessionID).jsonl" }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 一份会话的假树；返回打开着、第一页已经读完的对话。
    private func open(_ lines: [String], rawTail: String = "", clock: FollowClock = FollowClock(),
                      subagents: [String: Data] = [:]) async throws
        -> (sftp: MockSFTP, model: AgentHistoryModel, transcript: AgentTranscriptModel) {
        var data = ClaudeFixture.file(lines)
        data.append(Data(rawTail.utf8))
        var tree: [String: [RemoteEntry]] = [
            root: [ClaudeFixture.entry(project, directory: true)],
            "\(root)/\(project)": [ClaudeFixture.entry("\(ClaudeFixture.sessionID).jsonl", size: UInt64(data.count))],
        ]
        let sftp = MockSFTP()
        await sftp.setFile(path, data: data, mtime: Date())
        let subDir = "\(root)/\(project)/\(ClaudeFixture.sessionID)/subagents"
        tree[subDir] = subagents.map { ClaudeFixture.entry($0.key, size: UInt64($0.value.count)) }
        for (name, blob) in subagents { await sftp.setFile("\(subDir)/\(name)", data: blob, mtime: Date()) }
        await sftp.setTree(tree)
        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: sftp), preferredDirectory: ClaudeFixture.cwd,
                                      followTiming: clock.timing())
        await model.start()
        await waitUntil { !model.hasMore }
        model.select(try XCTUnwrap(model.files.first))
        let transcript = try XCTUnwrap(model.transcript)
        await waitUntil { transcript.reachedStart }
        return (sftp, model, transcript)
    }

    private func append(_ sftp: MockSFTP, _ text: String) async throws {
        var data = try await sftp.readRange(path, offset: 0, length: Int.max / 2)
        data.append(Data(text.utf8))
        await sftp.setFile(path, data: data, mtime: Date())
    }

    private func line(_ text: String) -> String { text + "\n" }

    // MARK: - 接上新内容

    /// 变长了：新条目接在后面，ID 不重复；新来的工具结果挂回前面已经显示的那次调用。
    func testAppendsNewItemsAndAttachesLateToolResults() async throws {
        let (sftp, _, transcript) = try await open([ClaudeFixture.userText("先看看日志")])
        XCTAssertEqual(transcript.items.map(\.kind), [.userText("先看看日志")])
        let before = transcript.appendGeneration

        try await append(sftp, line(ClaudeFixture.assistant(
            ClaudeFixture.toolUse(id: "toolu_live", name: "Bash", input: #"{"command":"tail -n 20 app.log"}"#))))
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.count, 2)
        guard case .toolCall(let pending) = transcript.items.last?.kind else { return XCTFail("没接上调用") }
        XCTAssertNil(pending.result)
        XCTAssertGreaterThan(transcript.appendGeneration, before)

        try await append(sftp, line(ClaudeFixture.toolResult(id: "toolu_live", text: "一切正常")))
        try await append(sftp, line(ClaudeFixture.assistant(ClaudeFixture.textBlock("日志没问题"), uuid: "a-2")))
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.count, 3, "结果挂回调用，不单列")
        guard case .toolCall(let done) = transcript.items[1].kind else { return XCTFail("调用不见了") }
        XCTAssertEqual(done.result?.content.text, "一切正常")
        XCTAssertEqual(transcript.items.last?.kind, .assistantText("日志没问题"))
        XCTAssertEqual(Set(transcript.items.map(\.id)).count, transcript.items.count, "ID 有重复")

        // 没再变长：什么都不动。
        let generation = transcript.appendGeneration
        await transcript.followOnce()
        XCTAssertEqual(transcript.appendGeneration, generation)
        XCTAssertNil(transcript.errorMessage)
    }

    /// 最后一行还没写完：先不解析，写完了再接上，只接一次。
    func testUnfinishedLineWaitsForItsNewline() async throws {
        let (sftp, _, transcript) = try await open([ClaudeFixture.userText("问")])
        let answer = ClaudeFixture.assistant(ClaudeFixture.textBlock("答"))
        let half = answer.index(answer.startIndex, offsetBy: answer.count / 2)
        try await append(sftp, String(answer[..<half]))
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.count, 1, "半行不解析")
        XCTAssertTrue(transcript.isUpdating, "文件在变")

        try await append(sftp, String(answer[half...]) + "\n")
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.map(\.kind), [.userText("问"), .assistantText("答")])
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.count, 2)
    }

    /// 打开时最后一行正写到一半：倒着读时解析不出来，写完之后从那一行的开头整行读到。
    func testLineHalfWrittenWhenOpenedShowsUpOnceFinished() async throws {
        let answer = ClaudeFixture.assistant(ClaudeFixture.textBlock("打开时还在写"))
        let half = answer.index(answer.startIndex, offsetBy: answer.count / 2)
        let (sftp, _, transcript) = try await open([ClaudeFixture.userText("问")], rawTail: String(answer[..<half]))
        XCTAssertEqual(transcript.items.map(\.kind), [.userText("问")])
        try await append(sftp, String(answer[half...]) + "\n")
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.map(\.kind), [.userText("问"), .assistantText("打开时还在写")])
    }

    /// 打开时最后一行已经是完整的 JSON、只差换行：倒着读时已经显示了，补上换行后不会再加一遍。
    func testCompleteLastLineWithoutNewlineIsNotDuplicated() async throws {
        let answer = ClaudeFixture.assistant(ClaudeFixture.textBlock("差个换行"))
        let (sftp, _, transcript) = try await open([ClaudeFixture.userText("问")], rawTail: answer)
        XCTAssertEqual(transcript.items.count, 2)
        try await append(sftp, "\n" + line(ClaudeFixture.userText("又问", uuid: "u-2")))
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.map(\.kind), [.userText("问"), .assistantText("差个换行"), .userText("又问")])
        XCTAssertEqual(Set(transcript.items.map(\.id)).count, 3)
    }

    /// 文件变短（被截断、换掉）：整份从末尾重读。
    func testShorterFileIsReloadedFromTheEnd() async throws {
        let (sftp, _, transcript) = try await open([ClaudeFixture.userText("旧的第一句"),
                                                    ClaudeFixture.assistant(ClaudeFixture.textBlock("旧的回答"))])
        XCTAssertEqual(transcript.items.count, 2)
        await sftp.setFile(path, data: ClaudeFixture.file([ClaudeFixture.userText("新")]), mtime: Date())
        await transcript.followOnce()
        await waitUntil { transcript.reachedStart && !transcript.isLoading }
        XCTAssertEqual(transcript.items.map(\.kind), [.userText("新")])
        // 之后接着跟新文件。
        try await append(sftp, line(ClaudeFixture.assistant(ClaudeFixture.textBlock("新的回答"))))
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.map(\.kind), [.userText("新"), .assistantText("新的回答")])
    }

    /// 一下子长了很多：一次只读一段，马上接着读（不等下一拍）。
    func testLargeGrowthIsReadInSlices() async throws {
        let sftp = MockSFTP()
        await sftp.setFile(path, data: ClaudeFixture.file([ClaudeFixture.userText("开头")]), mtime: Date())
        let pager = ClaudeTranscriptPager(provider: sftp, path: path, chunkBytes: 256, followBytes: 1024)
        _ = try await pager.loadPrevious()
        var appended = ""
        for index in 0..<20 { appended += line(ClaudeFixture.userText("第 \(index) 句", uuid: "u-\(index)")) }
        try await append(sftp, appended)
        var collected: [AgentTranscriptItem] = []
        var rounds = 0
        while true {
            rounds += 1
            guard case .appended(let items, let hasMore) = try await pager.loadNewer() else { return XCTFail("没读到") }
            collected += items
            if !hasMore { break }
        }
        XCTAssertGreaterThan(rounds, 1)
        XCTAssertEqual(collected.map(\.kind), (0..<20).map { .userText("第 \($0) 句") })
        let growth = try await pager.loadNewer()
        XCTAssertEqual(growth, .unchanged)
    }

    /// 第一页还没读（不知道末尾在哪）时不往后读。
    func testNothingBeforeTheFirstPage() async throws {
        let sftp = MockSFTP()
        await sftp.setFile(path, data: ClaudeFixture.file([ClaudeFixture.userText("a")]), mtime: Date())
        let pager = ClaudeTranscriptPager(provider: sftp, path: path)
        let growth = try await pager.loadNewer()
        XCTAssertEqual(growth, .unchanged)
        let stats = await sftp.statCalls
        XCTAssertEqual(stats, [])
    }

    // MARK: - 看不见不查、退避

    /// 看不见时一次 `stat` 都不发；看得见马上查一次、之后按节奏查；又看不见就停。只有正在显示的那一层在查。
    func testPollsOnlyWhileVisible() async throws {
        let (sftp, model, transcript) = try await open([ClaudeFixture.userText("问")])
        XCTAssertFalse(transcript.isFollowing)
        let initial = await sftp.statCalls.count
        try await Task.sleep(for: .milliseconds(150))
        let idle = await sftp.statCalls.count
        XCTAssertEqual(idle, initial, "没人看着不该查")

        model.setTranscriptVisible(true)
        XCTAssertTrue(transcript.isFollowing)
        try await Task.sleep(for: .milliseconds(150))
        let watching = await sftp.statCalls.count
        XCTAssertGreaterThanOrEqual(watching - idle, 3, "看得见：马上查一次，之后接着查")

        model.setTranscriptVisible(false)
        XCTAssertFalse(transcript.isFollowing)
        try await Task.sleep(for: .milliseconds(30))
        let stopped = await sftp.statCalls.count
        try await Task.sleep(for: .milliseconds(150))
        let after = await sftp.statCalls.count
        XCTAssertEqual(after, stopped, "看不见了还在查")

        // 换一份会话：旧的那份不再查。
        model.setTranscriptVisible(true)
        model.select(nil)
        XCTAssertFalse(transcript.isFollowing)
    }

    /// 读失败（断线）：不报错，间隔 2 → 4 → 8 → 16 → 30 → 30 秒地退；恢复后回到 2 秒并接上断开期间写的内容。
    func testBacksOffQuietlyAndRecovers() async throws {
        let clock = FollowClock()
        let (sftp, _, transcript) = try await open([ClaudeFixture.userText("问")], clock: clock)
        let first = await transcript.followOnce()
        XCTAssertEqual(first, .seconds(2))
        struct Offline: Error {}
        await sftp.setStatError(Offline())
        var delays: [Duration] = []
        for _ in 0..<6 { delays.append(await transcript.followOnce()) }
        XCTAssertEqual(delays, [.seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30), .seconds(30)])
        XCTAssertEqual(transcript.consecutiveFollowFailures, 6)
        XCTAssertNil(transcript.errorMessage, "断线不弹错")

        try await append(sftp, line(ClaudeFixture.assistant(ClaudeFixture.textBlock("断线时写的"))))
        await sftp.setStatError(nil)
        let back = await transcript.followOnce()
        XCTAssertEqual(back, .seconds(2))
        XCTAssertEqual(transcript.consecutiveFollowFailures, 0)
        XCTAssertEqual(transcript.items.last?.kind, .assistantText("断线时写的"))
    }

    /// 跟随的循环真的按退避的间隔睡（睡是假的，记下要睡多久）。
    func testFollowLoopSleepsTheBackoffDelays() async throws {
        let clock = FollowClock()
        let (sftp, model, _) = try await open([ClaudeFixture.userText("问")], clock: clock)
        struct Offline: Error {}
        await sftp.setStatError(Offline())
        model.setTranscriptVisible(true)
        await waitUntil { clock.requestedSleeps.count >= 5 }
        model.setTranscriptVisible(false)
        XCTAssertEqual(Array(clock.requestedSleeps.prefix(5)),
                       [.seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    }

    // MARK: - 状态

    /// 「正在更新」：最近 60 秒里读到过新内容；「有新消息」：往上翻着时末尾来了新条目，回到底部就消掉。
    func testUpdatingMarkAndNewMessagesHint() async throws {
        let clock = FollowClock()
        let (sftp, _, transcript) = try await open([ClaudeFixture.userText("问")], clock: clock)
        await transcript.followOnce()
        XCTAssertFalse(transcript.isUpdating)

        transcript.setFollowsTail(false)
        try await append(sftp, line(ClaudeFixture.assistant(ClaudeFixture.textBlock("答"))))
        await transcript.followOnce()
        XCTAssertTrue(transcript.isUpdating)
        XCTAssertTrue(transcript.hasNewBelow)
        transcript.setFollowsTail(true)
        XCTAssertFalse(transcript.hasNewBelow)

        // 停在底部时来新内容：不提示（界面跟着滚到底）。
        try await append(sftp, line(ClaudeFixture.userText("再问", uuid: "u-2")))
        await transcript.followOnce()
        XCTAssertFalse(transcript.hasNewBelow)

        clock.advance(.seconds(61))
        await transcript.followOnce()
        XCTAssertFalse(transcript.isUpdating, "一分钟没动静就不算在更新")
    }

    /// 会话开着时派了子代理：调用和记录先后写出来，接上之后入口也跟着出来。
    func testSubagentSpawnedWhileFollowingGetsItsEntry() async throws {
        let clock = FollowClock()
        let (sftp, _, transcript) = try await open([ClaudeFixture.userText("派一个去查")], clock: clock)
        try await append(sftp, line(ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_new", description: "去查"))))
        await transcript.followOnce()
        await waitUntil { !transcript.items.isEmpty }
        XCTAssertTrue(transcript.subagentLinks.isEmpty, "记录还没写出来")

        // 记录写出来了（带 meta）。
        let subDir = "\(root)/\(project)/\(ClaudeFixture.sessionID)/subagents"
        let record = ClaudeFixture.file([ClaudeFixture.sidechainUser("去查", agentID: "n1")])
        let meta = ClaudeFixture.subagentMeta(toolUseID: "toolu_new", description: "去查")
        await sftp.setFile("\(subDir)/agent-n1.jsonl", data: record, mtime: Date())
        await sftp.setFile("\(subDir)/agent-n1.meta.json", data: meta, mtime: Date())
        let tree = await sftp.tree
        var next = tree
        next[subDir] = [ClaudeFixture.entry("agent-n1.jsonl", size: UInt64(record.count)),
                        ClaudeFixture.entry("agent-n1.meta.json", size: UInt64(meta.count))]
        await sftp.setTree(next)
        clock.advance(.seconds(6))
        await transcript.followOnce()
        await waitUntil { transcript.subagentLinks["toolu_new"] != nil }
        XCTAssertEqual(transcript.subagentLinks["toolu_new"]?.file.agentID, "n1")
    }
}
