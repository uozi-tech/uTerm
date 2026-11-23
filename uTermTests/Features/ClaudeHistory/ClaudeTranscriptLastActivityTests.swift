import XCTest
@testable import uTerm

/// 顶栏的「最后活动」：已加载内容里最新那条的时间。实时跟随接上新的就变新，往前翻旧页不改旧，从搜索命中处打开时
/// 是已加载部分里最新那条的（不是文件末尾的）。手写的假记录，时钟是假的。
@MainActor
final class ClaudeTranscriptLastActivityTests: XCTestCase {
    private let path = "/home/user/.claude/projects/-p/0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b.jsonl"
    private static let fixedStamp = "2026-11-20T10:00:00.000Z"

    /// `ClaudeFixture` 的行都是同一个时间戳：换成 `minutes` 分钟后的那一刻。
    private func at(_ minutes: Int, _ line: String) -> String {
        line.replacingOccurrences(of: Self.fixedStamp, with: Self.stamp(minutes))
    }

    private static let base = ClaudeTimestamp.parse(fixedStamp)!
    private static func date(_ minutes: Int) -> Date { base.addingTimeInterval(TimeInterval(minutes * 60)) }
    private static func stamp(_ minutes: Int) -> String {
        date(minutes).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func turns(_ range: ClosedRange<Int>) -> [String] {
        range.flatMap { turn in
            [at(turn, ClaudeFixture.userText("问题 \(turn)", uuid: "u-\(turn)")),
             at(turn, ClaudeFixture.assistant(ClaudeFixture.textBlock("回答 \(turn)"), uuid: "a-\(turn)"))]
        }
    }

    private func timing(date: Date) -> AgentTranscriptFollowTiming {
        var timing = FollowClock().timing()
        timing.date = { date }
        return timing
    }

    private func sftp(_ lines: [String]) async -> MockSFTP {
        let sftp = MockSFTP()
        await sftp.setFile(path, data: ClaudeFixture.file(lines), mtime: Date())
        return sftp
    }

    private func file(size: Int) -> AgentHistorySessionFile {
        let project = AgentHistoryProject(id: "-p", path: "/home/user/.claude/projects/-p", modifiedAt: nil)
        return AgentHistorySessionFile(sessionID: "0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b", project: project, path: path,
                                       size: UInt64(size), modifiedAt: Self.date(-600))
    }

    func testFollowMovesItForwardAndOlderPagesNeverMoveItBack() async throws {
        let sftp = await sftp(turns(1...60))
        let now = Self.date(1_000)
        let transcript = AgentTranscriptModel(
            file: file(size: 0),
            pager: ClaudeTranscriptPager(provider: sftp, path: path, chunkBytes: 2048, pageItems: 6),
            followTiming: timing(date: now))
        await transcript.loadEarlier()
        XCTAssertFalse(transcript.reachedStart)
        XCTAssertEqual(transcript.lastActivity, Self.date(60), "第一页里最新那条")

        // 往前翻旧页：不改旧。
        await transcript.loadEarlier()
        await transcript.loadEarlier()
        XCTAssertEqual(transcript.lastActivity, Self.date(60))

        // 跟随接上一条带新时间戳的。
        var data = try await sftp.readRange(path, offset: 0, length: Int.max / 2)
        data.append(Data((at(75, ClaudeFixture.userText("新的问题", uuid: "u-new")) + "\n").utf8))
        await sftp.setFile(path, data: data, mtime: Date())
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.last?.kind, .userText("新的问题"))
        XCTAssertEqual(transcript.lastActivity, Self.date(75))

        // 接上一条没带时间戳的：记成读到它的那一刻。
        data.append(Data((ClaudeFixture.userText("没有时间戳", uuid: "u-bare")
            .replacingOccurrences(of: #""timestamp":"\#(Self.fixedStamp)","#, with: "") + "\n").utf8))
        await sftp.setFile(path, data: data, mtime: Date())
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.last?.kind, .userText("没有时间戳"))
        XCTAssertEqual(transcript.lastActivity, now)

        // 顶栏的字跟着它走。
        XCTAssertEqual(AgentHistoryText.transcriptDetail(transcript, metadata: nil).split(separator: "·").last?
            .trimmingCharacters(in: .whitespaces), AgentHistoryText.relative(now))
    }

    func testOpeningAtAHitUsesTheNewestLoadedItemNotTheFileEnd() async throws {
        let lines = turns(1...40)
        let sftp = await sftp(lines)
        var offset = 0
        var offsets: [Int] = []
        for line in lines {
            offsets.append(offset)
            offset += line.utf8.count + 1
        }
        let hit = 20   // 「问题 11」
        let anchor = AgentTranscriptAnchor(lineOffset: UInt64(offsets[hit]), lineLength: offsets[hit + 1] - offsets[hit] - 1)
        let transcript = AgentTranscriptModel(
            file: file(size: offset),
            pager: ClaudeTranscriptPager(provider: sftp, path: path, anchor: anchor, chunkBytes: 2048, pageItems: 6),
            followTiming: timing(date: Self.date(5_000)), opensAt: "\(offsets[hit]).0")
        await transcript.loadEarlier()
        XCTAssertEqual(transcript.items.last?.kind, .userText("问题 11"))
        XCTAssertEqual(transcript.lastActivity, Self.date(11), "命中那条的时间，不是文件末尾（40）的")
        // 跟随在读到末尾之前不干活，也不会把时间改成此刻。
        await transcript.followOnce()
        XCTAssertEqual(transcript.lastActivity, Self.date(11))
        // 往后读一页：跟着变新。
        await transcript.loadLater()
        XCTAssertGreaterThan(try XCTUnwrap(transcript.lastActivity), Self.date(11))
    }

    func testSubagentHeaderUsesItToo() {
        let link = AgentSubagentLink(file: AgentSubagentFile(agentID: "a1", path: "/x/agent-a1.jsonl", size: 10,
                                                             modifiedAt: Self.date(-10_000), hasInfo: false),
                                     agentType: "Explore", description: "查慢查询")
        XCTAssertTrue(AgentHistoryText.subagentDetail(link, lastActivity: Self.date(0))
            .hasSuffix(" · " + AgentHistoryText.relative(Self.date(0))))
        XCTAssertTrue(AgentHistoryText.subagentDetail(link).hasSuffix(" · " + AgentHistoryText.relative(Self.date(-10_000))),
                      "没有就退回记录文件的修改时间")
    }
}
