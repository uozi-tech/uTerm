import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 终端键盘按标签裁决：只有「已连接 + 拥有键盘」的那个会话能当第一响应者。
///
/// 钉的是实机回归：第一个标签已连上、再开第二个标签，建连过程中键盘冒出来——那是 UIKit
/// 收起新建抽屉时把第一个标签的终端恢复成第一响应者，不经过任何我们的聚焦调用。
/// 所以这里直接对终端视图调 `becomeFirstResponder()`（等价于 UIKit 的自动恢复）。
@MainActor
final class MobileTerminalKeyboardTests: XCTestCase {

    private var window: UIWindow?

    // async 版 tearDown 跑在主 actor 上；同步版是 nonisolated，碰不了窗口与探针夹具。
    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    private func host() throws -> (ModelContainer, ServerProfile, HostKeyChallengeRelay) {
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let h = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        return (c, h, HostKeyChallengeRelay())
    }

    /// 把若干控制器的终端视图挂进同一个真窗口（不在窗口里的视图当不了第一响应者）。
    private func mount(_ controllers: [MobileTerminalController]) -> [MTerminalView] {
        let root = UIViewController()
        let win: UIWindow
        if let scene = MobileProbeWindow.activeScene() {
            win = UIWindow(windowScene: scene)
        } else {
            win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        win.rootViewController = root
        win.makeKeyAndVisible()
        window = win
        return controllers.enumerated().map { i, controller in
            let view = MTerminalView(frame: CGRect(x: 0, y: CGFloat(i) * 200, width: 390, height: 200),
                                     font: .monospacedSystemFont(ofSize: 11, weight: .regular))
            view.controller = controller
            controller.attach(view)
            root.view.addSubview(view)
            return view
        }
    }

    func testConnectingTabNeverTakesKeyboardWhileOtherTabIsConnected() async throws {
        let (c, h, relay) = try host()
        let (a, _) = MobileFakeTerminal.controller(.idle)
        let (b, _) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, connectLatency: .seconds(30)))
        let views = mount([a, b])
        a.start(profile: h, container: c, relay: relay)
        b.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(a)
        XCTAssertTrue(connected)

        // 第一个标签：已连接、拥有键盘 → 能弹。
        a.ownsKeyboard = true
        a.focusKeyboard()
        XCTAssertTrue(views[0].isFirstResponder)

        // 开第二个标签：归属移交给正在建连的 B，A 当场收键盘。
        a.ownsKeyboard = false
        b.ownsKeyboard = true
        XCTAssertFalse(views[0].isFirstResponder)

        // B 还在建连：自己的聚焦与 UIKit 的自动恢复都拿不到键盘；A 也不行（已不是归属者）。
        XCTAssertEqual(b.state, .connecting)
        b.focusKeyboard()
        XCTAssertFalse(views[1].isFirstResponder)
        XCTAssertFalse(views[1].becomeFirstResponder())
        XCTAssertFalse(views[0].becomeFirstResponder())
        XCTAssertFalse(views[0].isFirstResponder)

        a.close()
        b.close()
    }

    func testFailedTabDoesNotTakeKeyboard() async throws {
        let (c, h, relay) = try host()
        let (failing, _) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, connectFailure: "connection refused"))
        let views = mount([failing])
        failing.ownsKeyboard = true
        failing.start(profile: h, container: c, relay: relay)
        let failed = await MobileFakeTerminal.waitUntil {
            if case .failed = failing.state { return true }
            return false
        }
        XCTAssertTrue(failed)

        failing.focusKeyboard()
        XCTAssertFalse(views[0].isFirstResponder)
        XCTAssertFalse(views[0].becomeFirstResponder())
    }

    func testLosingConnectionResignsKeyboard() async throws {
        let (c, h, relay) = try host()
        let (a, _) = MobileFakeTerminal.controller(.idle)
        let views = mount([a])
        a.ownsKeyboard = true
        a.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(a)
        XCTAssertTrue(connected)
        a.focusKeyboard()
        XCTAssertTrue(views[0].isFirstResponder)

        a.close()
        XCTAssertFalse(views[0].isFirstResponder)
    }

    /// 用户收起键盘后，自动聚焦（切标签、关抽屉、转屏都走 `focusKeyboard`）不能把它弹回来；
    /// 点按钮或点终端才弹。工作区裁决归属造成的收键盘不算用户收起，归属回来照常弹。
    func testCollapsedKeyboardStaysDownUntilTheUserAsksForIt() async throws {
        let (c, h, relay) = try host()
        let (a, _) = MobileFakeTerminal.controller(.idle)
        let view = mount([a])[0]
        a.ownsKeyboard = true
        a.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(a)
        XCTAssertTrue(connected)
        a.focusKeyboard()
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(a.keyboardShown)

        // 归属移走再回来：不是用户收的，弹回。
        a.ownsKeyboard = false
        XCTAssertFalse(a.keyboardShown)
        a.ownsKeyboard = true
        a.focusKeyboard()
        XCTAssertTrue(view.isFirstResponder)

        // 用户收起：自动聚焦不弹，归属来回也不弹。
        a.collapseKeyboard()
        XCTAssertFalse(view.isFirstResponder)
        XCTAssertFalse(a.keyboardShown)
        a.focusKeyboard()
        a.ownsKeyboard = false
        a.ownsKeyboard = true
        a.focusKeyboard()
        XCTAssertFalse(view.isFirstResponder)

        // 点按钮弹出。
        a.showKeyboard()
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(a.keyboardShown)

        // 点终端（SwiftTerm 直接聚焦视图）也算要回键盘：之后的自动聚焦恢复正常。
        a.collapseKeyboard()
        XCTAssertTrue(view.becomeFirstResponder())
        a.ownsKeyboard = false
        a.ownsKeyboard = true
        a.focusKeyboard()
        XCTAssertTrue(view.isFirstResponder)

        a.close()
    }

    /// 提示词的字节顺序：回车必须单独一包，否则 Codex 不提交（文字留在输入框）。
    /// 程序开了括号粘贴（`CSI ? 2004 h`）才包粘贴标记，没开就发纯文本，标记不能漏进 shell。
    func testPromptIsPastedThenSubmittedInSeparateWrite() async throws {
        let (c, h, relay) = try host()
        let (a, handles) = MobileFakeTerminal.controller(.idle)
        let view = mount([a])[0]
        a.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(a)
        XCTAssertTrue(connected)
        let fake = try XCTUnwrap(handles.issued.first)

        /// 等上行攒够 `count` 包。假传输是 actor，只能这样轮询。
        func writes(reaching count: Int) async -> [Data] {
            for _ in 0..<100 {
                let writes = await fake.writes
                if writes.count >= count { return writes }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return await fake.writes
        }
        func packets(_ text: String...) -> [Data] { text.map { Data($0.utf8) } }

        a.submitPrompt("继续")
        let raw = await writes(reaching: 2)
        XCTAssertEqual(raw, packets("继续", "\r"))

        view.feed(text: "\u{1b}[?2004h")
        a.submitPrompt("继续")
        let pasted = await writes(reaching: 4)
        XCTAssertEqual(Array(pasted.suffix(2)), packets("\u{1b}[200~继续\u{1b}[201~", "\r"))

        // 只填入：不带回车。
        a.insertPrompt("/compact")
        try await Task.sleep(for: .milliseconds(300))
        let filled = await fake.writes
        XCTAssertEqual(filled.count, 5)
        XCTAssertEqual(filled.last, Data("\u{1b}[200~/compact\u{1b}[201~".utf8))

        a.close()
    }

    /// 横屏键盘弹起后只剩两百多点高：会话主体不能超出，否则键盘条被挤到屏外、连收键盘的按钮都点不到。
    /// 撑高的是隐藏着的 Agent 空状态（没配模型服务时）。
    func testSessionBodyFitsTheHeightLeftByALandscapeKeyboard() throws {
        let (c, h, _) = try host()
        let body = TerminalSessionBody(tab: TermTab(host: h, transportFactory: MobileFakeTerminal.controller(.idle).1.factory),
                                       onClose: {})
            .environment(MobileStore())
            .modelContainer(c)
        let hosting = UIHostingController(rootView: body)
        let fitted = hosting.sizeThatFits(in: CGSize(width: 874, height: 176))
        XCTAssertLessThanOrEqual(fitted.height, 176)
    }

    /// 面板只给占屏的系统键盘让位：外接键盘的快捷栏、收起动画的终点都不算。
    func testOnlyAScreenCoveringKeyboardCountsAsUp() {
        func covers(minY: CGFloat, height: CGFloat) -> Bool {
            MKeyBarKeyboard.coversScreen(frame: CGRect(x: 0, y: minY, width: 402, height: height),
                                                screenHeight: 874)
        }
        XCTAssertTrue(covers(minY: 874 - 336, height: 336), "系统键盘")
        XCTAssertFalse(covers(minY: 874, height: 336), "收起动画的终点：高度还在，但已经在屏外")
        XCTAssertFalse(covers(minY: 874 - 55, height: 55), "外接键盘时的快捷栏")
    }

    func testQuickTapIsLeftToTheButton() async throws {
        let repeater = KeyRepeater()
        var sent = 0
        repeater.press { sent += 1 }
        repeater.release()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(sent, 0)
        XCTAssertFalse(repeater.didRepeat, "没连发过，松手时 Button 要发这一次")
    }

    func testHoldingRepeatsUntilRelease() async throws {
        let repeater = KeyRepeater()
        var sent = 0
        repeater.press { sent += 1 }
        let deadline = ContinuousClock.now + .seconds(3)
        while sent < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(sent, 2)
        repeater.release()
        let atRelease = sent
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sent, atRelease, "松手后不能再发")
        XCTAssertTrue(repeater.didRepeat, "连发过，松手时 Button 不能再多发一次")
    }

    func testKeyCatalogIsUsableInAGrid() {
        // `id` 就是 label：同一组里重复会让 ForEach 串键。
        let groups = [TerminalKeyCatalog.primary, TerminalKeyCatalog.arrows, TerminalKeyCatalog.shellSymbols,
                      TerminalKeyCatalog.navigation, TerminalKeyCatalog.control, TerminalKeyCatalog.function,
                      TerminalKeyCatalog.symbols, TerminalKeyCatalog.agentKeys]
        for group in groups { XCTAssertEqual(Set(group.map(\.id)).count, group.count) }
        XCTAssertEqual(Set(TerminalKeyCatalog.prompts).count, TerminalKeyCatalog.prompts.count)
        for prompt in TerminalKeyCatalog.prompts + TerminalKeyCatalog.slashCommands {
            XCTAssertFalse(prompt.unicodeScalars.contains { $0.value < 0x20 }, "提示词不能带控制字符：\(prompt)")
        }
    }

    /// 输入法：默认要英文键盘；拼音组字时光标处能看到正在拼的字，上屏后叠层收起、字发给终端。
    func testDefaultsToEnglishAndShowsMarkedTextAtTheCursor() async throws {
        let (c, h, relay) = try host()
        let (a, _) = MobileFakeTerminal.controller(.idle)
        let views = mount([a])
        let view = views[0]
        a.ownsKeyboard = true
        a.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(a)
        XCTAssertTrue(connected)
        a.focusKeyboard()

        if UITextInputMode.activeInputModes.contains(where: { $0.primaryLanguage?.hasPrefix("en") == true }) {
            XCTAssertEqual(view.textInputMode?.primaryLanguage?.hasPrefix("en"), true)
        }

        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        let overlay = view.subviews.compactMap { $0 as? UILabel }.first { $0.text == "ni" }
        let label = try XCTUnwrap(overlay, "组字中的文字应当显示在终端上")
        XCTAssertFalse(label.isHidden)
        if let caret = view.textInputCaretFrame {
            XCTAssertEqual(label.frame.minY, caret.minY, accuracy: 0.5, "叠层贴着光标那一行")
            XCTAssertEqual(view.caretRect(for: view.beginningOfDocument), caret, "候选框跟着光标，而不是整个视图")
        }

        view.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(label.text, "你")
        view.unmarkText()
        XCTAssertTrue(label.isHidden, "上屏后叠层收起")
        a.close()
    }
}
