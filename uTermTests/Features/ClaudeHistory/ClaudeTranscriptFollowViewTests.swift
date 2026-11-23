import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 实时跟随在真视图里的滚动：停在底部时新内容来了跟着到底；往上翻着时不动位置（已有内容不跳）、底部亮「有新消息」。
/// 对话挂在屏内透明窗口里（`ProbeWindow`），记录是手写的假数据。
@MainActor
final class ClaudeTranscriptFollowViewTests: XCTestCase {
    private let root = "/home/user/.claude/projects"
    private let project = "-home-user-projects-demo"
    private var path: String { "\(root)/\(project)/\(ClaudeFixture.sessionID).jsonl" }

    private func settle(_ seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// 内容顶端到视口顶端的距离（不管文档视图是不是翻转的坐标）。
    private func topOffset(_ scroll: NSScrollView) -> CGFloat {
        let visible = scroll.documentVisibleRect
        let height = scroll.documentView?.bounds.height ?? 0
        return (scroll.documentView?.isFlipped ?? true) ? visible.minY : height - visible.maxY
    }

    private func distanceFromBottom(_ scroll: NSScrollView) -> CGFloat {
        let visible = scroll.documentVisibleRect
        let height = scroll.documentView?.bounds.height ?? 0
        return (scroll.documentView?.isFlipped ?? true) ? height - visible.maxY : visible.minY
    }

    func testFollowsAtBottomAndHoldsPositionWhenScrolledUp() async throws {
        var lines: [String] = []
        for turn in 0..<30 {
            lines.append(ClaudeFixture.userText("第 \(turn) 个问题：这一步该怎么做？", uuid: "u-\(turn)"))
            lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("第 \(turn) 个回答：先看日志，再看配置。"),
                                                 uuid: "a-\(turn)"))
        }
        let sftp = MockSFTP()
        await sftp.setFile(path, data: ClaudeFixture.file(lines), mtime: Date())
        let file = AgentHistorySessionFile(sessionID: ClaudeFixture.sessionID,
                                           project: AgentHistoryProject(id: project, path: "\(root)/\(project)", modifiedAt: nil),
                                           path: path, size: 0, modifiedAt: Date())
        let transcript = AgentTranscriptModel(file: file, pager: ClaudeTranscriptPager(provider: sftp, path: path))
        while !transcript.reachedStart { await transcript.loadEarlier() }

        let rect = NSRect(x: 0, y: 0, width: 760, height: 460)
        let host = NSHostingView(rootView: AgentTranscriptPane(transcript: transcript, metadata: nil, canResume: false,
                                                               onResume: {}))
        host.frame = rect
        let window = ProbeWindow.make(contentRect: rect, contentView: host, placement: .transparentOnScreen)
        defer { window.orderOut(nil) }
        await settle()
        let scroll = try XCTUnwrap(host.firstScrollView())
        XCTAssertLessThan(distanceFromBottom(scroll), 4, "打开时停在最后一条")

        var turn = 100
        func appendTurn() async throws {
            var data = try await sftp.readRange(path, offset: 0, length: Int.max / 2)
            data.append(Data((ClaudeFixture.userText("新的问题 \(turn)", uuid: "n-\(turn)") + "\n"
                + ClaudeFixture.assistant(ClaudeFixture.textBlock("新的回答 \(turn)"), uuid: "m-\(turn)") + "\n").utf8))
            turn += 1
            await sftp.setFile(path, data: data, mtime: Date())
            await transcript.followOnce()
        }

        // 停在底部：跟着到底。
        try await appendTurn()
        await settle()
        XCTAssertLessThan(distanceFromBottom(scroll), 4, "停在底部时新内容来了没跟到底")
        XCTAssertFalse(transcript.hasNewBelow)

        // 往上翻（真的滚轮事件，带手势相位；界面在滚动停下来时报「不在底部」）：新内容来了位置不动、亮提示。
        try await scroll.simulateTrackpadScroll(up: 1200)
        await settle(0.4)
        XCTAssertGreaterThan(distanceFromBottom(scroll), 600, "滚轮没把对话往上翻")
        let before = topOffset(scroll)
        let heightBefore = scroll.documentView?.bounds.height ?? 0
        try await appendTurn()
        await settle()
        let heightAfter = scroll.documentView?.bounds.height ?? 0
        XCTAssertGreaterThan(heightAfter, heightBefore, "新内容没画出来")
        XCTAssertEqual(topOffset(scroll), before, accuracy: 2, "往上翻着时新内容让已有内容跳了")
        XCTAssertTrue(transcript.hasNewBelow)
        print("[claude-follow-view] top offset \(before) → \(topOffset(scroll)), document \(heightBefore) → \(heightAfter)")
    }
}
