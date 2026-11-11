import AppKit
import SwiftUI
import XCTest
@testable import uTerm

@MainActor
@Observable
private final class SwitchTabs {
    var active: TerminalSession
    init(active: TerminalSession) { self.active = active }
}

private struct SwitchHost: View {
    let tabs: SwitchTabs
    var body: some View {
        RemoteControlledTerminal(session: tabs.active)
            .id(ObjectIdentifier(tabs.active))
            .frame(width: 800, height: 500)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Mac 上反复切标签：每次露出之后，surface 都要建好、视图尺寸等于窗格、画面上有这个标签的内容（不能留一片空白）。
/// 视图出生时是零尺寸（surface 要等容器提交真实尺寸才建），任何露出路径都得最终按真实尺寸提交一次。
@MainActor
final class GhosttyTabSwitchTests: XCTestCase {
    private var sessions: [TerminalSession] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        sessions.forEach { $0.dispose() }
        sessions = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        try await super.tearDown()
    }

    private func makeSession(tag: String, connected: Bool = true) async -> TerminalSession {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        sessions.append(session)
        if connected {
            await session.connect(using: MockBackend())
            session.feedOutput(text: "\u{1B}[2J\u{1B}[H\(tag)\r\n$ ")
        }
        return session
    }

    private func host(_ tabs: SwitchTabs) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: 800, height: 500)
        let hosting = NSHostingView(rootView: SwitchHost(tabs: tabs))
        hosting.frame = rect
        let window = ProbeWindow.make(contentRect: rect, contentView: hosting, placement: .transparentOnScreen, keepsDrawing: true)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    private func sleep(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// 露出之后的状态；全部满足返回 nil，否则返回哪一条没满足。
    private func problem(_ session: TerminalSession, tag: String) -> String? {
        let view = session.ghostty.view
        guard let container = view.superview as? GhosttyContainerView else { return "视图不在容器里" }
        guard view.window != nil else { return "视图不在窗口里" }
        if view.uTermIsSurfaceReleased { return "surface 被放掉了没重建" }
        let i = GhosttyContainerView.insets
        let expected = NSSize(width: container.bounds.width - i.left - i.right, height: container.bounds.height - i.top - i.bottom)
        guard container.bounds.width > 0 else { return "容器零宽" }
        if abs(view.frame.width - expected.width) > 0.5 || view.frame.height < expected.height - 0.5 || view.frame.height > expected.height + 0.5 {
            return "视图尺寸 \(view.frame.size) ≠ 窗格 \(expected)"
        }
        if !view.uTermCanRenderFrame { return "surface 建着但引擎不出帧（被标成不可见 / 被遮挡）" }
        guard session.ghostty.grid != nil else { return "surface 还没报过网格" }
        if !(session.ghostty.viewportText() ?? "").contains(tag) {
            return "画面上没有 \(tag)（影子里有：\(session.shadow.viewportText().contains(tag))，surface 在吃字节：\(session.outputPump.isFeedingSurface)，在屏上：\(session.ghostty.isOnScreen)，surface 网格 \(String(describing: session.surfaceIO.surfaceGrid))，泵 \(session.outputPump.currentStats)）"
        }
        return nil
    }

    private func assertShown(_ session: TerminalSession, tag: String, _ context: String,
                             file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        var last = problem(session, tag: tag)
        while last != nil, Date() < deadline {
            await sleep(20)
            last = problem(session, tag: tag)
        }
        if last != nil {
            // 区分「surface 没拿到内容」和「只是没画/没解析」：再喂一段字，看它出不出现。
            let bar = session.ghostty.view.uTermScrollbar
            _ = session.ghostty.view.performBindingAction("scroll_to_bottom")
            await sleep(300)
            let afterScroll = (session.ghostty.viewportText() ?? "").contains(tag)
            session.feedOutput(text: "ZZZ-PROBE")
            await sleep(500)
            let probe = (session.ghostty.viewportText() ?? "").contains("ZZZ-PROBE")
            XCTFail("\(context)：露出后一直是空白——\(last ?? "")；再喂一段字，surface 上\(probe ? "能" : "也不")出现；滚动条 \(String(describing: bar))；滚到底后有内容：\(afterScroll)；surface 文字 \(String(((session.ghostty.viewportText() ?? "").split(separator: "\n", omittingEmptySubsequences: false).enumerated().filter { !$0.element.isEmpty }.map { "\($0.offset):\($0.element)" }).joined(separator: "|")))；影子文字 \((session.shadow.viewportText().split(separator: "\n", omittingEmptySubsequences: false).enumerated().filter { !$0.element.isEmpty }.map { "\($0.offset):\($0.element)" }).joined(separator: "|"))；影子网格 \(session.shadow.size)", file: file, line: line)
        }
    }

    /// 快速来回切（间隔从 0 到几百毫秒），每次停下来都要有内容。
    func testRapidSwitchingAlwaysEndsWithContent() async throws {
        let a = await makeSession(tag: "TAB-A"), b = await makeSession(tag: "TAB-B"), c = await makeSession(tag: "TAB-C")
        let tabs = SwitchTabs(active: a)
        _ = host(tabs)
        await assertShown(a, tag: "TAB-A", "首次挂载")
        let all = [(a, "TAB-A"), (b, "TAB-B"), (c, "TAB-C")]
        for gap in [0, 10, 40, 90, 150, 300] {
            for round in 0..<8 {
                let (session, tag) = all[(round * 2 + gap) % 3]
                tabs.active = session
                await sleep(gap)
                if round % 3 == 2 {
                    await assertShown(session, tag: tag, "间隔 \(gap) ms 第 \(round) 次")
                }
            }
            let (session, tag) = all[gap % 3]
            tabs.active = session
            await assertShown(session, tag: tag, "间隔 \(gap) ms 最后一次")
        }
    }

    /// 藏起来超过放掉 surface 的延迟再切回：surface 要重建、内容要回来。
    func testSwitchingBackAfterTheSurfaceWasReleased() async throws {
        let a = await makeSession(tag: "TAB-A"), b = await makeSession(tag: "TAB-B")
        for s in [a, b] { s.ghostty.hiddenReleaseDelay = .milliseconds(40) }
        let tabs = SwitchTabs(active: a)
        _ = host(tabs)
        await assertShown(a, tag: "TAB-A", "首次挂载")
        tabs.active = b
        await assertShown(b, tag: "TAB-B", "切到 B")
        for round in 0..<4 {
            await sleep(250)
            XCTAssertTrue(a.ghostty.isSurfaceReleased, "用例前提：A 藏了一会儿，surface 已放掉（第 \(round) 轮）")
            tabs.active = a
            await assertShown(a, tag: "TAB-A", "放掉后切回 A（第 \(round) 轮）")
            await sleep(250)
            tabs.active = b
            await assertShown(b, tag: "TAB-B", "放掉后切回 B（第 \(round) 轮）")
        }
    }

    /// 新建标签（视图从没排过版）马上切走、再切回来。
    func testNewTabSwitchedAwayImmediately() async throws {
        let a = await makeSession(tag: "TAB-A")
        let tabs = SwitchTabs(active: a)
        _ = host(tabs)
        await assertShown(a, tag: "TAB-A", "首次挂载")
        for (round, gap) in [0, 5, 30, 70, 120].enumerated() {
            let fresh = await makeSession(tag: "TAB-N\(round)")
            tabs.active = fresh
            await sleep(gap)
            tabs.active = a
            await sleep(gap)
            tabs.active = fresh
            await assertShown(fresh, tag: "TAB-N\(round)", "新标签间隔 \(gap) ms")
            tabs.active = a
            await assertShown(a, tag: "TAB-A", "回到 A（新标签间隔 \(gap) ms）")
        }
    }
}
