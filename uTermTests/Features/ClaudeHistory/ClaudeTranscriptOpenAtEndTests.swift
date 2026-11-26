import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 打开一份历史会话要停在最后一条上（用户报：点开会话，停在离底差一截的地方，最后一两条在视口下面）。
///
/// 判据是最后一条的文字在屏上的位置，不是滚动视图报的「离文档底多远」：懒栈里没建出来的行高度是按已建的行估的，
/// 文档高度跟着是估的。整份对话都在懒栈里的时候，打开停到的是「估出来的底」，那个差值照样是 0，最后几条却还在视口下面
///（行高不齐时估的底和真的底能差几屏；估高了就是滚过头，最后一条下面空一大片）。所以每份假对话的最后一条是一句记号，
/// 找画它的那个视图，看它的底边是不是贴着视口的底。
///
/// 假对话的行高故意不齐（真实会话就是这样：工具调用折成一行二十几点高，一条长回答上千点）。行高整齐的对话估得准，
/// 这个问题露不出来。改法见 `AgentTranscriptMessages`：末尾那一段不进懒栈。
@MainActor
final class ClaudeTranscriptOpenAtEndTests: XCTestCase {
    private let root = "/home/user/.claude/projects"
    private let project = "-home-user-projects-demo"
    private var path: String { "\(root)/\(project)/\(ClaudeFixture.sessionID).jsonl" }

    /// 最后一条的文字（单独一段）。
    private static let lastLine = "对话到这里结束"

    // MARK: 假对话

    private func tools(_ count: Int, tag: String) -> [String] {
        var lines: [String] = []
        for call in 0..<count {
            let id = "t-\(tag)-\(call)"
            lines.append(ClaudeFixture.assistant(
                ClaudeFixture.toolUse(id: id, name: call % 2 == 0 ? "Bash" : "Read", input: #"{"command":"ls -la /tmp/\#(call)"}"#),
                uuid: "c-\(tag)-\(call)"))
            lines.append(ClaudeFixture.user(
                content: #"[{"tool_use_id":"\#(id)","type":"tool_result","content":"ok","is_error":false}]"#,
                uuid: "r-\(tag)-\(call)"))
        }
        return lines
    }

    /// 一条回答：标题、几段话、可选的代码块和表格、一个列表。
    private func answer(paragraphs: Int, code: Int = 0, table: Int = 0, tag: String) -> String {
        var text = "## 回答 \(tag)"
        for index in 0..<paragraphs {
            text += "\n\n第 \(index) 段：先确认日志里的报错，再对照配置文件逐项排查，最后改完重跑一遍测试。" +
                String(repeating: "检查服务账号的权限、目录的属主和挂载选项。", count: index % 3 + 1)
        }
        if code > 0 {
            text += "\n\n```swift\n" + (0..<code).map { "let value\($0) = compute(\($0)) // 注释 \($0)" }.joined(separator: "\n") + "\n```"
        }
        if table > 0 {
            text += "\n\n| 项 | 值 | 说明 |\n|---|---|---|\n" + (0..<table).map { "| 第 \($0) 项 | \($0 * 7) | 说明文字 \($0) |" }.joined(separator: "\n")
        }
        text += "\n\n- 一\n- 二\n- 三"
        return ClaudeFixture.assistant(ClaudeFixture.textBlock(text), uuid: "a-\(tag)")
    }

    private func shortTurn(_ turn: Int) -> [String] {
        [ClaudeFixture.userText("第 \(turn) 个问题", uuid: "u-\(turn)")] + tools(2, tag: "\(turn)")
            + [ClaudeFixture.assistant(ClaudeFixture.textBlock("好的。"), uuid: "a-\(turn)")]
    }

    private enum Shape: String, CaseIterable {
        /// 每一轮都一样长。
        case uniform
        /// 前面全是短行，最后一条回答很长（最常见：一路调用工具，最后给一大段总结）。
        case tallTail
        /// 反过来：前面几条很长，后面全是短行。
        case tallHead
        /// 越往后越长 / 越往后越短。
        case growing, shrinking
        /// 一条一条的短行（每次调用之间夹一句话，折不成组），最后一条长的。
        case manyShortRows
        /// 思考、长短不一的问题、有时带代码块或表格。
        case mixed
        /// 不满一页（顶上没有「加载更早的消息」），但比一屏长得多。
        case onePage
        /// 一页里的行比整段排的上限（`AgentTranscriptLimits.eagerTailRows`）还多：前面的行在懒栈里，末尾那一段照样要准。
        case longPage
    }

    private func lines(_ shape: Shape) -> [String] {
        var lines: [String] = []
        switch shape {
        case .uniform:
            for turn in 0..<24 {
                lines.append(ClaudeFixture.userText("第 \(turn) 个问题：这一步该怎么做？", uuid: "u-\(turn)"))
                lines += tools(3, tag: "\(turn)")
                lines.append(answer(paragraphs: 6, tag: "\(turn)"))
            }
        case .tallTail:
            for turn in 0..<14 { lines += shortTurn(turn) }
            lines.append(ClaudeFixture.userText("最后一个问题：总结一下", uuid: "u-last"))
            lines += tools(4, tag: "last")
            lines.append(answer(paragraphs: 30, code: 40, table: 12, tag: "last"))
        case .tallHead:
            for turn in 0..<4 {
                lines.append(ClaudeFixture.userText("第 \(turn) 个问题", uuid: "u-\(turn)"))
                lines.append(answer(paragraphs: 30, code: 40, table: 12, tag: "\(turn)"))
            }
            for turn in 4..<16 { lines += shortTurn(turn) }
        case .growing, .shrinking:
            for turn in 0..<14 {
                let size = shape == .growing ? turn : 13 - turn
                lines.append(ClaudeFixture.userText("第 \(turn) 个问题", uuid: "u-\(turn)"))
                lines += tools(1 + turn % 3, tag: "\(turn)")
                lines.append(answer(paragraphs: size * 2, code: size, tag: "\(turn)"))
            }
        case .manyShortRows:
            for turn in 0..<60 {
                lines += tools(1, tag: "\(turn)")
                lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("第 \(turn) 步做完了。"), uuid: "a-\(turn)"))
            }
            lines.append(answer(paragraphs: 12, code: 20, tag: "last"))
        case .mixed:
            for turn in 0..<12 {
                lines.append(ClaudeFixture.userText("第 \(turn) 个问题：" + String(repeating: "这里贴了一段很长的说明。", count: turn * 4),
                                                    uuid: "u-\(turn)"))
                lines.append(ClaudeFixture.assistant(ClaudeFixture.thinkingBlock("先想一想 \(turn)"), uuid: "th-\(turn)"))
                lines += tools(turn % 4, tag: "\(turn)")
                lines.append(answer(paragraphs: turn % 5, code: turn % 3 * 15, table: turn % 2 * 8, tag: "\(turn)"))
            }
        case .longPage:
            for turn in 0..<150 {
                lines += tools(1, tag: "\(turn)")
                lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("第 \(turn) 步做完了。"), uuid: "a-\(turn)"))
            }
            lines.append(answer(paragraphs: 30, code: 40, table: 12, tag: "last"))
        case .onePage:
            lines.append(ClaudeFixture.userText("问题", uuid: "u-0"))
            lines += tools(3, tag: "0")
            lines.append(answer(paragraphs: 30, code: 40, table: 12, tag: "0"))
            lines.append(ClaudeFixture.userText("再问", uuid: "u-1"))
            lines.append(answer(paragraphs: 20, code: 10, tag: "1"))
        }
        lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("都改完了。\n\n\(Self.lastLine)"), uuid: "a-end"))
        return lines
    }

    // MARK: 量

    /// 对话的滚动视图：最外面那个（代码块是嵌在里面横着滚的）。
    private func transcriptScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = transcriptScroll(sub) { return found }
        }
        return nil
    }

    /// 最后一条的文字离视口底边多远（正数 = 它的底边在视口底边上面）；那一行没建出来、或者藏着，为 nil。
    private func lastLineAboveViewportBottom(_ scroll: NSScrollView) -> CGFloat? {
        distanceAboveViewportBottom(of: Self.lastLine, in: scroll)
    }

    /// 这段文字的底边离视口底边多远。能选中的文字（`.textSelection(.enabled)`）在 AppKit 这边各有一个视图，
    /// 文字在它的辅助功能值里；懒栈回收了的行，视图还在、是藏着的。
    private func distanceAboveViewportBottom(of text: String, in scroll: NSScrollView) -> CGFloat? {
        guard let document = scroll.documentView else { return nil }
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        var found: CGFloat?
        func walk(_ view: NSView) {
            if let value = view.accessibilityValue() as? String, value.contains(text), !view.isHiddenOrHasHiddenAncestor {
                // 窗口坐标 y 朝上。
                found = view.convert(view.bounds, to: nil).minY - viewport.minY
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(document)
        return found
    }

    /// 贴着底：最后一条的底边在视口底边上面一点（下面只剩底部留白，12pt 上下），没被挤出去，下面也没空出一大片。
    private func isAtEnd(_ distance: CGFloat?) -> Bool {
        distance.map { $0 >= 0 && $0 <= 40 } ?? false
    }

    private enum Opening: String {
        /// App 里真实的顺序：对话先挂出来（空的、读取中），第一页之后才到。
        case firstPageAfterMount
        /// 走整条路：历史列表模型选中会话（对话层挂上、第一页在读、实时跟随同时盯着文件末尾）。
        case selectedInHistory
        /// 第一页读完了才挂。
        case mountedWithContent
    }

    /// 打开一份对话，等它停稳，返回最后一条离视口底边多远。
    private func open(_ shape: Shape, size: NSSize, opening: Opening) async throws -> CGFloat? {
        let lines = lines(shape)
        let rect = NSRect(origin: .zero, size: size)
        let host: NSView
        var history: AgentHistoryModel?
        switch opening {
        case .selectedInHistory:
            typealias F = ClaudeSearchFixture
            let sftp = await F.host([(1, F.session(lines, title: "很长的对话"), 60, F.project)])
            let model = AgentHistoryModel(source: ClaudeHistorySource(provider: sftp), preferredDirectory: F.directory,
                                          followsCurrentProject: false)
            await model.start()
            for _ in 0..<400 where model.visibleFiles.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            // 没选会话时这一层是空的，给它定好尺寸（App 里外面那层撑满；不定的话宿主视图缩成 0，量什么都是 0）。
            host = NSHostingView(rootView: AgentHistoryTranscriptStack(history: model, onResume: { _ in })
                .frame(width: size.width, height: size.height))
            history = model
        case .firstPageAfterMount, .mountedWithContent:
            let sftp = MockSFTP()
            await sftp.setFile(path, data: ClaudeFixture.file(lines), mtime: Date())
            let file = AgentHistorySessionFile(sessionID: ClaudeFixture.sessionID,
                                               project: AgentHistoryProject(id: project, path: "\(root)/\(project)", modifiedAt: nil),
                                               path: path, size: 0, modifiedAt: Date())
            let transcript = AgentTranscriptModel(file: file, pager: ClaudeTranscriptPager(provider: sftp, path: path))
            if opening == .mountedWithContent { await transcript.loadEarlier() }
            host = NSHostingView(rootView: AgentTranscriptPane(transcript: transcript, metadata: nil, canResume: false, onResume: {})
                .frame(width: size.width, height: size.height))
            if opening == .firstPageAfterMount {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    await transcript.loadEarlier()
                }
            }
        }
        host.frame = rect
        let window = ProbeWindow.make(contentRect: rect, contentView: host, placement: .transparentOnScreen)
        defer { window.orderOut(nil) }
        if let history {
            try? await Task.sleep(for: .milliseconds(200))
            let file = try XCTUnwrap(history.visibleFiles.first)
            history.setTranscriptVisible(true)
            history.select(file)
        }
        // 等它贴到底（最多 2 秒），再等一会儿确认没又跳走。
        var distance: CGFloat?
        for _ in 0..<100 {
            distance = transcriptScroll(host).flatMap(lastLineAboveViewportBottom)
            if isAtEnd(distance) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(transcriptScroll(host), "对话的滚动视图没挂出来")
        distance = lastLineAboveViewportBottom(scroll)
        let visible = scroll.documentVisibleRect
        print("[transcript-open] \(shape.rawValue) \(opening.rawValue) \(Int(size.width))x\(Int(size.height))："
            + "最后一条离视口底 \(distance.map { "\($0)" } ?? "没建出来")，文档 \(scroll.documentView?.bounds.height ?? 0)，"
            + "视口 \(visible.minY)–\(visible.maxY)")
        return distance
    }

    /// 各种行高分布、两种窗口尺寸都打开一遍；没停在最后一条的列出来。
    private func assertOpensAtEnd(_ opening: Opening, shapes: [Shape] = Shape.allCases,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        var misses: [String] = []
        for shape in shapes {
            for size in [NSSize(width: 1200, height: 700), NSSize(width: 760, height: 460)] {
                let distance = try await open(shape, size: size, opening: opening)
                if !isAtEnd(distance) {
                    misses.append("\(shape.rawValue) \(Int(size.width))×\(Int(size.height))："
                        + (distance.map { "最后一条的底边在视口底边上面 \($0)pt" } ?? "最后一条没建出来（在视口外面）"))
                }
            }
        }
        XCTAssertTrue(misses.isEmpty, "打开后没停在最后一条：\n" + misses.joined(separator: "\n"), file: file, line: line)
    }

    // MARK: 用例

    /// 用户报的那一种，单独一条：前面是短行、最后一条回答很长，先挂空的、第一页后到。
    func testOpensAtLastMessageWhenItIsMuchTallerThanEarlierRows() async throws {
        let distance = try await open(.tallTail, size: NSSize(width: 1200, height: 700), opening: .firstPageAfterMount)
        XCTAssertTrue(isAtEnd(distance), "打开后没停在最后一条："
            + (distance.map { "最后一条的底边在视口底边上面 \($0)pt" } ?? "最后一条没建出来（在视口外面）"))
    }

    /// 整段排的那一段（`tailStartID` 往后）就是打开时读进来的那一页：往前加页不把更早的行算进来。
    func testTailStartStaysOnTheFirstOpenedPageWhenEarlierPagesLoad() async throws {
        var lines: [String] = []
        // 一页按字节读（至少一块 256 KB）：垫上够长的工具输出，记录才分得成几页。
        for turn in 0..<60 {
            lines += shortTurn(turn)
            lines.append(ClaudeFixture.assistant(ClaudeFixture.toolUse(id: "big-\(turn)", name: "Bash", input: #"{"command":"cat app.log"}"#),
                                                 uuid: "bc-\(turn)"))
            lines.append(ClaudeFixture.toolResult(id: "big-\(turn)", text: String(repeating: "-rw-r--r-- 1 deploy deploy 0 app.log\n", count: 400)))
        }
        let sftp = MockSFTP()
        await sftp.setFile(path, data: ClaudeFixture.file(lines), mtime: Date())
        let file = AgentHistorySessionFile(sessionID: ClaudeFixture.sessionID,
                                           project: AgentHistoryProject(id: project, path: "\(root)/\(project)", modifiedAt: nil),
                                           path: path, size: 0, modifiedAt: Date())
        let transcript = AgentTranscriptModel(file: file, pager: ClaudeTranscriptPager(provider: sftp, path: path))
        XCTAssertNil(transcript.tailStartID)
        await transcript.loadEarlier()
        let firstPage = transcript.items.map(\.id)
        XCTAssertEqual(transcript.tailStartID, firstPage.first)
        XCTAssertFalse(transcript.reachedStart, "要有更早的页可加")

        await transcript.loadEarlier()
        let all = transcript.items.map(\.id)
        XCTAssertGreaterThan(all.count, firstPage.count, "没加上更早的一页")
        let start = try XCTUnwrap(transcript.tailStartID.flatMap { all.firstIndex(of: $0) }, "末尾那一段的第一条不在对话里了")
        XCTAssertGreaterThan(start, 0, "更早的那一页被算进了末尾那一段")
        // 第一页开头落单的工具结果会挂到更早那页的调用上（那一条就没了），其余的一条不少、一条不多。
        XCTAssertEqual(Array(all[start...]), firstPage.filter(Set(all).contains))
    }

    /// 从搜索命中处打开：停在命中的那一条上（它在视口里），不是末尾。第一页回来之前滚动视图还没挂，挂上时要滚过去。
    func testOpensAtSearchHitWhenFirstPageArrivesAfterMount() async throws {
        let hitText = "命中的就是这一句"
        var lines: [String] = []
        for turn in 0..<8 { lines += shortTurn(turn) }
        lines.append(answer(paragraphs: 20, code: 30, tag: "before"))
        let hitIndex = lines.count
        lines.append(ClaudeFixture.userText(hitText, uuid: "u-hit"))
        lines.append(answer(paragraphs: 30, code: 40, table: 12, tag: "after"))
        for turn in 8..<16 { lines += shortTurn(turn) }
        let offset = lines[..<hitIndex].reduce(0) { $0 + $1.utf8.count + 1 }
        let anchor = AgentTranscriptAnchor(lineOffset: UInt64(offset), lineLength: lines[hitIndex].utf8.count)

        let sftp = MockSFTP()
        await sftp.setFile(path, data: ClaudeFixture.file(lines), mtime: Date())
        let file = AgentHistorySessionFile(sessionID: ClaudeFixture.sessionID,
                                           project: AgentHistoryProject(id: project, path: "\(root)/\(project)", modifiedAt: nil),
                                           path: path, size: 0, modifiedAt: Date())
        let transcript = AgentTranscriptModel(file: file, pager: ClaudeTranscriptPager(provider: sftp, path: path, anchor: anchor),
                                              opensAt: "\(offset).0")
        let size = NSSize(width: 1200, height: 700)
        let rect = NSRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: AgentTranscriptPane(transcript: transcript, metadata: nil, canResume: false, onResume: {})
            .frame(width: size.width, height: size.height))
        host.frame = rect
        let window = ProbeWindow.make(contentRect: rect, contentView: host, placement: .transparentOnScreen)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(300))
        await transcript.loadEarlier()
        XCTAssertTrue(transcript.items.contains { $0.kind == .userText(hitText) }, "命中的那一条没读进来")
        try? await Task.sleep(for: .milliseconds(800))
        let scroll = try XCTUnwrap(transcriptScroll(host), "对话的滚动视图没挂出来")
        let distance = distanceAboveViewportBottom(of: hitText, in: scroll)
        let viewport = scroll.documentVisibleRect.height
        print("[transcript-open] 命中处：离视口底 \(distance.map { "\($0)" } ?? "没建出来")，视口高 \(viewport)，文档 \(scroll.documentView?.bounds.height ?? 0)")
        let shown = try XCTUnwrap(distance, "命中的那一条没建出来（在视口外面）")
        XCTAssertGreaterThanOrEqual(shown, 0, "命中的那一条在视口下面")
        XCTAssertLessThanOrEqual(shown, viewport - 16, "命中的那一条在视口上面")
    }

    func testOpensAtLastMessageWhenFirstPageArrivesAfterMount() async throws {
        try await assertOpensAtEnd(.firstPageAfterMount)
    }

    func testOpensAtLastMessageWhenSelectedThroughHistoryModel() async throws {
        try await assertOpensAtEnd(.selectedInHistory)
    }

    func testOpensAtLastMessageWhenMountedWithContent() async throws {
        try await assertOpensAtEnd(.mountedWithContent)
    }
}
