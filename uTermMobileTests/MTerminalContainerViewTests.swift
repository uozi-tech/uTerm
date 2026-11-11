import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 两份容器用例（本文件与 `MTerminalContainerAdoptionTests`）共用的夹具：一条 Ghostty 终端挂进 `MTerminalContainerView`。
///
/// 「容器有没有把尺寸 / 字号交给终端」看两层：
/// - 容器提交的直接结果是终端视图的 `frame` 和 `terminalFontSize`，不挂窗口也能核（`hosted()`）；
/// - 行列数、程序会收到几次尺寸通知要有 surface：挂进真窗口（`hostedInWindow()`），读终端自己报来的网格和报的次数
///   （`reported(_:)`）。网格只在变了的时候报（`suppressesPixelOnlyResizes`），每报一次远端收到一次 SIGWINCH。
@MainActor
class MTerminalContainerTestCase: XCTestCase {
    /// 终端自己报来的网格，以及到此刻一共报过几次。
    nonisolated struct Reported: Equatable, Sendable {
        var cols: Int
        var rows: Int
        var count: Int

        var grid: [Int] { [cols, rows] }
    }

    /// 两个测试类共用一个 ghostty app（一份字体 / 图集缓存），和生产时所有终端共用一个一样。
    private static let controller = GhosttyTerminalBridge.makeController(
        fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))

    let mounted = CGSize(width: 400, height: 600)
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.subviews.forEach { $0.removeFromSuperview() }
        window?.isHidden = true
        window = nil
    }

    func makeTerminal() -> GhosttyTerminalBridge {
        GhosttyTerminalBridge(controller: Self.controller)
    }

    /// 已按 `mounted` 排过版的终端，不挂窗口（没有 surface）：只核容器交给终端的 frame 和字号。
    func hosted() async -> (GhosttyTerminalBridge, MTerminalContainerView) {
        let bridge = makeTerminal()
        let container = MTerminalContainerView(terminal: bridge, fontSize: 11)
        lay(container, mounted)
        await settle()
        return (bridge, container)
    }

    /// 已按 `mounted` 排过版、挂在真窗口里、surface 已就绪（网格到位、画面在吃字节）的终端。
    /// 基线用 `reported(_:)` 取：它会等网格停稳。
    func hostedInWindow(fontSize: CGFloat = 11, file: StaticString = #filePath, line: UInt = #line) async throws
        -> (GhosttyTerminalBridge, MTerminalContainerView) {
        let bridge = makeTerminal()
        let container = MTerminalContainerView(terminal: bridge, fontSize: fontSize)
        try mount(container)
        lay(container, mounted)
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "surface 没就绪：ready=\(bridge.isSurfaceReady) feeding=\(bridge.outputPump.isFeedingSurface)",
                      file: file, line: line)
        return (bridge, container)
    }

    /// 把容器挂进测试窗口。外壳切换的用例里新容器也要挂上：生产里新表示层同样在窗口里。
    func mount(_ container: MTerminalContainerView) throws {
        let window = try self.window ?? makeSpikeWindow(size: mounted)
        self.window = window
        window.addSubview(container)
    }

    func lay(_ container: MTerminalContainerView, _ size: CGSize) {
        container.frame = CGRect(origin: .zero, size: size)
        container.layoutIfNeeded()
    }

    /// 等容器的顺延计时到点。
    func settle() async {
        try? await Task.sleep(for: MTerminalContainerView.settleDelay * 3)
    }

    /// 终端报来的网格与次数。网格由 IO 线程异步报来（挨着的几次 resize 还会合并），所以等它 0.3 s 不再变才读。
    func reported(_ bridge: GhosttyTerminalBridge) async -> Reported {
        func read() -> Reported {
            Reported(cols: bridge.grid?.cols ?? 0, rows: bridge.grid?.rows ?? 0, count: bridge.resizeReports)
        }
        var last = read()
        var stableSince = ContinuousClock.now
        let deadline = stableSince + .seconds(3)
        while ContinuousClock.now < deadline, ContinuousClock.now - stableSince < .milliseconds(300) {
            try? await Task.sleep(for: .milliseconds(20))
            let now = read()
            if now != last {
                last = now
                stableSince = ContinuousClock.now
            }
        }
        return last
    }

    /// 画面（surface）上此刻的视口文字。
    func surfaceText(_ bridge: GhosttyTerminalBridge) -> String {
        bridge.session.waitForPendingOutput()
        return bridge.session.readViewportText() ?? ""
    }

    func feed(_ bridge: GhosttyTerminalBridge, _ text: String) {
        bridge.feed(Data(text.utf8))
    }

    /// 提交后终端视图该在哪：铺满容器，再按「按行填满」往下挪零头的上半份（`TerminalSurfaceLink.rowFillOffset`，
    /// 尺寸不变；没有 surface 时是 0）。UIKit 存 frame 时有浮点误差，纵向位置按容差比。
    func assertCommitted(_ bridge: GhosttyTerminalBridge, _ size: CGSize, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
        let frame = bridge.view.frame
        XCTAssertEqual(frame.size, size, message, file: file, line: line)
        XCTAssertEqual(frame.minX, 0, message, file: file, line: line)
        XCTAssertEqual(frame.minY, bridge.link.rowFillOffset, accuracy: 0.001, message, file: file, line: line)
    }
}

/// 终端尺寸停稳才提交：中途的尺寸不碰终端，提交时才通知程序。
@MainActor
final class MTerminalContainerViewTests: MTerminalContainerTestCase {
    func testFirstLayoutCommitsImmediately() {
        let bridge = makeTerminal()
        let container = MTerminalContainerView(terminal: bridge, fontSize: 11)

        lay(container, mounted)

        XCTAssertTrue(container.terminalView === bridge.view)
        XCTAssertEqual(bridge.view.frame.size, mounted)
    }

    /// 键盘升起又收起：终端里的内容不能被碰，程序也不该收到尺寸通知。
    func testRoundTripLeavesBufferUntouched() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)
        let rows = (1...before.rows).map { "\u{1b}[\($0);1Hrow \($0)" }.joined()
        feed(bridge, "\u{1b}[?1049h" + rows)
        let screen = surfaceText(bridge)
        let shadow = bridge.shadow.viewportText()
        let cursor = bridge.shadow.cursor
        XCTAssertTrue(screen.contains("row \(before.rows)"), "自证：内容已经在画面上")

        lay(container, CGSize(width: 400, height: 300))
        lay(container, mounted)
        await settle()

        let after = await reported(bridge)
        XCTAssertEqual(after, before, "没停住就不该通知程序")
        assertCommitted(bridge, mounted)
        XCTAssertEqual(surfaceText(bridge), screen)
        XCTAssertEqual(bridge.shadow.viewportText(), shadow)
        XCTAssertEqual(bridge.shadow.cursor, cursor)
    }

    func testResizeCommitsOnceAfterSettling() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)

        for height in stride(from: 560, through: 300, by: -40) {
            lay(container, CGSize(width: 400, height: CGFloat(height)))
            XCTAssertEqual(bridge.view.frame.size, mounted, "停稳之前不能重排")
        }
        await settle()

        assertCommitted(bridge, CGSize(width: 400, height: 320))
        let after = await reported(bridge)
        XCTAssertEqual(after.cols, before.cols)
        XCTAssertLessThan(after.rows, before.rows)
        XCTAssertEqual(after.count, before.count + 1, "一串中间尺寸只通知程序一次")
        let shadow = bridge.shadow.size
        XCTAssertEqual([shadow.cols, shadow.rows], after.grid, "影子终端跟着同一次通知改尺寸")
    }

    /// 键盘升起的等待期间，终端底部（提示符和光标）要留在屏上。
    func testHeldTerminalKeepsBottomVisibleWhenTallerThanContainer() async {
        let (bridge, container) = await hosted()

        lay(container, CGSize(width: 400, height: 300))

        XCTAssertEqual(bridge.view.frame.height, mounted.height)
        XCTAssertEqual(bridge.view.frame.maxY, 300)
    }

    /// 字号和宽度一起变（切分屏）：只重排一次，程序也只收到一次通知。
    func testFontAndWidthCommitTogether() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)

        lay(container, CGSize(width: 200, height: 600))
        container.setFontSize(9)
        XCTAssertEqual(bridge.view.terminalFontSize, 11, accuracy: 0.01, "停稳之前不能换字号")
        XCTAssertEqual(bridge.view.frame.size, mounted, "停稳之前不能换尺寸")
        await settle()

        XCTAssertEqual(bridge.view.terminalFontSize, 9, accuracy: 0.01)
        XCTAssertEqual(bridge.view.frame.size.width, 200)
        let after = await reported(bridge)
        XCTAssertNotEqual(after.grid, before.grid)
        XCTAssertEqual(after.count, before.count + 1, "字号和宽度一起提交，程序只收到一次通知")
    }

    func testCollapsedContainerKeepsGrid() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)

        lay(container, .zero)
        await settle()

        let after = await reported(bridge)
        XCTAssertEqual(after, before)
        XCTAssertEqual(bridge.view.frame.size, mounted)
    }

    /// 外壳切换时新容器接走同一个终端，旧容器不再摆放它。
    func testStaleContainerDoesNotResizeAdoptedTerminal() async throws {
        let (bridge, stale) = try await hostedInWindow()
        let live = MTerminalContainerView(terminal: bridge, fontSize: 11)
        try mount(live)
        lay(live, mounted)
        let before = await reported(bridge)

        lay(stale, CGSize(width: 200, height: 300))
        await settle()

        let after = await reported(bridge)
        XCTAssertEqual(after, before)
        assertCommitted(bridge, mounted)
    }

    // MARK: 隐藏标签

    /// 转屏时隐藏标签不重排，里面的程序也收不到通知。
    func testHiddenContainerDoesNotFollowSize() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)
        container.isOnScreen = false
        XCTAssertFalse(bridge.isOnScreen)

        lay(container, CGSize(width: 200, height: 300))
        await settle()

        let after = await reported(bridge)
        XCTAssertEqual(after, before)
        XCTAssertEqual(bridge.view.frame.size, mounted)
    }

    /// 转到屏上的那一拍就提交，不用再等 80ms。
    func testShowingContainerCommitsOnNextLayout() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)
        container.isOnScreen = false
        lay(container, CGSize(width: 200, height: 300))

        container.isOnScreen = true
        container.layoutIfNeeded()

        assertCommitted(bridge, CGSize(width: 200, height: 300), "露出来的那一拍就提交")
        XCTAssertTrue(bridge.isOnScreen)
        let after = await reported(bridge)
        XCTAssertNotEqual(after.grid, before.grid)
        XCTAssertEqual(after.count, before.count + 1)
    }

    func testHidingCancelsPendingCommit() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)

        lay(container, CGSize(width: 200, height: 300))
        container.isOnScreen = false
        await settle()

        let after = await reported(bridge)
        XCTAssertEqual(after, before)
        XCTAssertEqual(bridge.view.frame.size, mounted)
    }

    /// 字号也要一起等：隐藏期间宽度变了，露出来时才一次换好。
    func testHiddenContainerHoldsFontSizeUntilShown() async {
        let (bridge, container) = await hosted()
        container.isOnScreen = false

        container.setFontSize(9)
        await settle()
        XCTAssertEqual(bridge.view.terminalFontSize, 11, accuracy: 0.01)

        container.isOnScreen = true
        container.layoutIfNeeded()
        XCTAssertEqual(bridge.view.terminalFontSize, 9, accuracy: 0.01)
    }

    /// 后台新开的标签也要按真实尺寸排版；它没露出过，所以不建 surface（露出来时直接按这个尺寸建）。
    func testFirstLayoutCommitsEvenWhenHidden() throws {
        let bridge = makeTerminal()
        let container = MTerminalContainerView(terminal: bridge, fontSize: 11)
        container.isOnScreen = false
        try mount(container)

        lay(container, mounted)

        XCTAssertEqual(bridge.view.frame.size, mounted)
        XCTAssertFalse(bridge.isOnScreen)
        XCTAssertNil(bridge.view.surface, "从没露出过的终端不建 surface")
    }

    // MARK: 换字号不重置终端状态

    /// 画面那个终端此刻的模式与画笔：DECRQM（方向键模式、自动折行、光标显隐、备用屏、插入模式）和
    /// DECRQSS（SGR）的应答。画面在吃字节时查询只由它答，应答经 write 回调出来。
    private func programState(_ bridge: GhosttyTerminalBridge) async -> String {
        func answers() -> String {
            String(decoding: (bridge.inputLog ?? []).reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
        }
        bridge.inputLog = []
        feed(bridge, "\u{1b}[?1$p\u{1b}[?7$p\u{1b}[?25$p\u{1b}[?1049$p\u{1b}[4$p\u{1b}P$qm\u{1b}\\")
        await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) {
            answers().components(separatedBy: "$y").count == 6 && answers().contains("$r")
        }
        let state = answers()
        bridge.inputLog = nil
        return state
    }

    /// 转屏时字号和宽度一起变：vim 里的方向键模式、隐藏的光标、当前颜色都不能丢。
    func testRotationKeepsProgramModes() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)
        feed(bridge, "\u{1b}[?1049h\u{1b}[?1h\u{1b}[?25l\u{1b}[?7l\u{1b}[4h\u{1b}[31m")
        let state = await programState(bridge)
        for answer in ["[?1;1$y", "[?7;2$y", "[?25;2$y", "[?1049;1$y", "[4;1$y", "31m"] {
            XCTAssertTrue(state.contains(answer), "自证：程序设的状态读得出来，缺 \(answer)：\(state.debugDescription)")
        }

        lay(container, CGSize(width: 800, height: 380))
        container.setFontSize(13)
        await settle()

        XCTAssertEqual(bridge.view.terminalFontSize, 13, accuracy: 0.01, "前提：这次转屏换了字号")
        let after = await reported(bridge)
        XCTAssertNotEqual(after.cols, before.cols)
        let stateAfter = await programState(bridge)
        XCTAssertEqual(stateAfter, state, "画面那个终端的模式和画笔不能被换字号重置")
        // 读状态用的影子终端跟着改了尺寸，模式同样还在。
        XCTAssertTrue(bridge.shadow.isModeSet(1), "方向键模式")
        XCTAssertTrue(bridge.shadow.isOnAlternateScreen)
        XCTAssertFalse(bridge.shadow.cursor.visible)
        XCTAssertFalse(bridge.shadow.isModeSet(7), "自动折行")
    }
}
