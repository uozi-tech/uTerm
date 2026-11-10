import XCTest
import AppKit
import Carbon.HIToolbox
@testable import uTerm

/// uTerm 的终端视图（原来是 SwiftTerm 上的 `CopyableTerminalView`，现在是 Ghostty 上的 `GhosttySurfaceView`）自己加的
/// 那几样：滚动条只在滚动时浮现、⌃↩、只有图片的剪贴板（⌘V / ⌃V）、右键菜单。文件名沿用旧的。
@MainActor
final class CopyableTerminalViewTests: XCTestCase {

    private var harnesses: [FocusedTerminal] = []

    override func tearDown() async throws {
        harnesses.forEach { $0.close() }
        harnesses = []
        try await super.tearDown()
    }

    private func focusedTerminal(onScreen: Bool = false) async -> FocusedTerminal {
        let harness = await FocusedTerminal(onScreen: onScreen)
        harnesses.append(harness)
        return harness
    }

    /// 滚动条的契约（2142cf7「滚动条改为仅滚动时浮现，根除常驻 knob」）换了引擎之后还在：Ghostty 自己不画滚动条，
    /// 终端视图里没有常驻的 NSScroller；容器自绘的滑块（`GhosttyScrollIndicator`）安装后默认全隐，可见性与
    /// 「有没有可滚的历史」解耦——只有用户实际滚动才浮现，停手约 1 s 淡出。
    ///
    /// 这里只覆盖可同步、确定性验证的安装期不变量；滚轮驱动的浮现、跟着视口走、淡出在
    /// `GhosttyMacHostTests.testScrollIndicatorShowsWhileScrollingAndTracksTheViewport`（真的 surface）。
    func testScrollIndicatorHiddenByDefaultAndNeverInterceptsTheMouse() async {
        let harness = await focusedTerminal()
        let container = GhosttyContainerView(surface: harness.view)
        harness.window.contentView?.addSubview(container)
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.layoutSubtreeIfNeeded()

        XCTAssertTrue(harness.view.subviews.compactMap { $0 as? NSScroller }.isEmpty, "终端视图里不该有常驻的 NSScroller")
        let indicator = container.scrollIndicator
        XCTAssertTrue(indicator.superview === container)
        XCTAssertFalse(indicator.isShown, "安装后默认隐藏——仅滚动时浮现")
        XCTAssertEqual(indicator.alphaValue, 0)
        XCTAssertTrue(indicator.isHidden, "没有可滚的历史：连位置都不摆")
        XCTAssertNil(indicator.hitTest(NSPoint(x: 1, y: 1)), "滑块只显示、不接鼠标：点它等于点终端")

        // 有了历史也不出现（旧的 SwiftTerm 默认行为是有历史就常驻显示）。
        harness.session.feedOutput(text: (1...200).map { "line \($0)\r\n" }.joined())
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(indicator.isShown, "有可滚历史但没滚动：仍然隐藏")
        XCTAssertEqual(indicator.alphaValue, 0)
    }

    // MARK: ⌃↩

    func testControlReturnSendsCarriageReturnInsteadOfOpeningContextMenu() async {
        let harness = await focusedTerminal()

        XCTAssertTrue(harness.view.performKeyEquivalent(with: returnKey(flags: .control)))

        let sent = await harness.sent(expecting: 1)
        XCTAssertEqual(sent, [13])
    }

    func testControlShiftReturnAndControlKeypadEnterAlsoStayInTerminal() async {
        let harness = await focusedTerminal()

        XCTAssertTrue(harness.view.performKeyEquivalent(with: returnKey(flags: [.control, .shift])))
        XCTAssertTrue(harness.view.performKeyEquivalent(
            with: returnKey(flags: .control, keyCode: UInt16(kVK_ANSI_KeypadEnter))))

        let sent = await harness.sent(expecting: 2)
        XCTAssertEqual(sent, [13, 13])
    }

    /// 程序开了 kitty 键盘协议（影子终端里看得到标志）：uTerm 不再替它发回车，交回 Ghostty 自己编带修饰键的序列。
    func testControlReturnUsesModifiedSequenceUnderKittyKeyboardProtocol() async {
        let harness = await focusedTerminal(onScreen: true)
        harness.session.feedOutput(text: "\u{1b}[>1u")
        XCTAssertNotEqual(harness.session.shadow.kittyKeyboardFlags, 0)
        // surface 是异步解析的：等它也吃到这几个字节（视口文字读一次要过它的终端锁，排在解析之后）。
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(harness.view.performKeyEquivalent(with: returnKey(flags: .control)))

        XCTAssertEqual(harness.intercepted, 0, "开了 kitty 协议：不走 uTerm 的回车")
        let sent = await harness.sent(expecting: 7)
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "\u{1b}[13;5u")
    }

    /// key equivalent 会发给窗口里的每个视图，分屏时不能让两个终端都收到回车。
    func testControlReturnIgnoredWhenTerminalIsNotFirstResponder() async {
        let harness = await focusedTerminal()
        harness.window.makeFirstResponder(nil)

        XCTAssertFalse(harness.view.performKeyEquivalent(with: returnKey(flags: .control)))

        let sent = await harness.sent(expecting: 1, timeout: 0.15)
        XCTAssertEqual(sent, [])
    }

    func testOtherReturnCombinationsStayOutOfKeyEquivalentPath() async {
        let harness = await focusedTerminal()

        XCTAssertFalse(harness.view.performKeyEquivalent(with: returnKey(flags: [])))
        let sent = await harness.sent(expecting: 1, timeout: 0.15)
        XCTAssertEqual(sent, [])

        // ⌘⌃↩ 不是 uTerm 截的那个组合：交给 Ghostty 自己处理（它怎么编码不在这里核）。
        _ = harness.view.performKeyEquivalent(with: returnKey(flags: [.command, .control]))
        XCTAssertEqual(harness.intercepted, 0)
    }

    private func commandKey(_ characters: String, _ keyCode: Int, _ flags: NSEvent.ModifierFlags,
                            in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(keyCode))!
    }

    private func appShortcuts(in window: NSWindow) -> [(name: String, event: NSEvent)] {
        [("⌘K 命令面板", commandKey("k", kVK_ANSI_K, .command, in: window)),
         ("⌘T 新标签", commandKey("t", kVK_ANSI_T, .command, in: window)),
         ("⌘N 新窗口", commandKey("n", kVK_ANSI_N, .command, in: window)),
         ("⌘⇧N", commandKey("N", kVK_ANSI_N, [.command, .shift], in: window)),
         ("⌘, 设置", commandKey(",", kVK_ANSI_Comma, .command, in: window)),
         ("⌘S", commandKey("s", kVK_ANSI_S, .command, in: window)),
         ("⌘D", commandKey("d", kVK_ANSI_D, .command, in: window)),
         ("⌘⇧D", commandKey("D", kVK_ANSI_D, [.command, .shift], in: window)),
         ("⌘W 关标签", commandKey("w", kVK_ANSI_W, .command, in: window)),
         ("⌘Q 退出", commandKey("q", kVK_ANSI_Q, .command, in: window)),
         ("⌘⌥1", commandKey("1", kVK_ANSI_1, [.command, .option], in: window)),
         ("⌘↩", returnKey(flags: .command))]
    }

    /// 终端有焦点时，uTerm 自己的窗口 / 菜单快捷键不能被终端视图吞掉。key equivalent 先问视图层级、再问菜单；
    /// Ghostty 自带一套默认按键绑定（⌘T 新标签、⌘W 关闭、⌘D 分屏、⌘K 清屏、⌘↩ 全屏……），GhosttyKit 的视图认了
    /// 绑定就返回 true，菜单再也收不到（SwiftTerm 的视图不认这些组合，全部落到菜单）。所以 ⌘ 组合先交给主菜单：
    /// 菜单接了就到此为止，Ghostty 不再处理、也不往程序里写东西。
    func testAppShortcutsGoToTheMenuBeforeGhosttyBindings() async {
        let harness = await focusedTerminal()
        harness.menuTakesEverything = true
        for (name, event) in appShortcuts(in: harness.window) {
            XCTAssertTrue(harness.view.performKeyEquivalent(with: event), name)
        }
        XCTAssertEqual(harness.offeredToMenu.count, 12, "每个 ⌘ 组合都先交给主菜单")
        let sent = await harness.sent(expecting: 1, timeout: 0.15)
        XCTAssertEqual(sent, [], "菜单接了：不该往程序里写东西")
    }

    /// 菜单不要的 ⌘ 组合交回 Ghostty。这里顺带把「没有菜单拦着时哪些会被 Ghostty 的默认绑定吃掉」打出来备查。
    func testCommandKeysTheMenuDeclinesFallBackToGhostty() async {
        let harness = await focusedTerminal()
        harness.menuTakesEverything = false
        var swallowed: [String] = []
        for (name, event) in appShortcuts(in: harness.window) where harness.view.performKeyEquivalent(with: event) {
            swallowed.append(name)
        }
        print("[终端快捷键] 菜单不接时被 Ghostty 默认绑定吃掉的：\(swallowed.isEmpty ? "无" : swallowed.joined(separator: "、"))")
        XCTAssertEqual(harness.offeredToMenu.count, 12, "菜单先被问过")
        XCTAssertTrue(swallowed.contains("⌘↩"), "⌘↩ 没有菜单项：落到 Ghostty 的绑定上")

        // 不是第一响应者、没按 ⌘ 的组合不问菜单。
        harness.offeredToMenu = []
        harness.window.makeFirstResponder(nil)
        _ = harness.view.performKeyEquivalent(with: commandKey("t", kVK_ANSI_T, .command, in: harness.window))
        harness.window.makeFirstResponder(harness.view)
        _ = harness.view.performKeyEquivalent(with: returnKey(flags: .control))
        XCTAssertEqual(harness.offeredToMenu.count, 0)
    }

    private func returnKey(
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16 = UInt16(kVK_Return)
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: keyCode)!
    }

    // MARK: 只有图片的剪贴板

    private func vKey(flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false,
                         keyCode: UInt16(kVK_ANSI_V))!
    }

    private func imagePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("uterm-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), forType: .png)
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    /// ⌘V / ⌃V 遇到只有图片的剪贴板：交给会话的贴图处理（`onPasteImage` / `onControlVImage`），它接了就不再走普通粘贴。
    func testImageOnlyPasteboardIsHandedToTheImageHooks() async {
        let harness = await focusedTerminal()
        harness.view.pasteboard = imagePasteboard()
        var pasted: [uTerm.TerminalImage] = []
        var controlV: [uTerm.TerminalImage] = []
        harness.view.onPasteImage = { pasted.append($0); return true }
        harness.view.onControlVImage = { controlV.append($0); return true }

        XCTAssertTrue(harness.view.performKeyEquivalent(with: vKey(flags: .command)))
        XCTAssertEqual(pasted.map(\.format), [.png])
        XCTAssertTrue(controlV.isEmpty)

        XCTAssertTrue(harness.view.performKeyEquivalent(with: vKey(flags: .control)))
        XCTAssertEqual(controlV.map(\.format), [.png])
        XCTAssertEqual(pasted.count, 1)

        // 菜单里的「粘贴」走的是 `paste(_:)`，同样先问贴图。
        harness.view.paste(nil)
        XCTAssertEqual(pasted.count, 2)
        let sent = await harness.sent(expecting: 1, timeout: 0.15)
        XCTAssertEqual(sent, [], "贴图处理接了：不往程序写别的")
    }

    /// 剪贴板里有文字时不是「只有图片」：不问贴图处理；别的终端是第一响应者时也不问。
    func testImageHooksAreNotConsultedForTextOrWhenNotFocused() async {
        let harness = await focusedTerminal()
        var asked = 0
        harness.view.onPasteImage = { _ in asked += 1; return true }
        harness.view.onControlVImage = { _ in asked += 1; return true }

        let withText = imagePasteboard()
        withText.setString("hello", forType: .string)
        harness.view.pasteboard = withText
        _ = harness.view.performKeyEquivalent(with: vKey(flags: .control))
        XCTAssertEqual(asked, 0, "带文字的剪贴板走普通路径")

        harness.view.pasteboard = imagePasteboard()
        harness.window.makeFirstResponder(nil)
        XCTAssertFalse(harness.view.performKeyEquivalent(with: vKey(flags: .command)))
        XCTAssertEqual(asked, 0, "不是第一响应者：key equivalent 会发给窗口里的每个视图，不能两个终端都贴")
    }

    // MARK: 右键菜单

    /// 拷贝 / 粘贴 / 全选，目标直接是这个终端视图（不管此刻第一响应者是谁）；没有选区时「拷贝」置灰。
    func testContextMenuTargetsThisTerminalAndDisablesCopyWithoutSelection() async throws {
        let harness = await focusedTerminal()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 10, y: 10),
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: harness.window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(harness.view.menu(for: event))
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.map(\.title), ["拷贝", "粘贴", "全选"])
        XCTAssertEqual(items.map(\.keyEquivalent), ["c", "v", "a"])
        for item in items {
            XCTAssertTrue(item.target === harness.view, "\(item.title) 的目标应当是这个终端")
        }
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertFalse(items[0].isEnabled, "没有选区：拷贝置灰")
        XCTAssertTrue(items[1].isEnabled)
        XCTAssertTrue(items[2].isEnabled)
    }
}

/// 挂在窗口里、已拿到焦点的终端（真的会话 + 假后端），并记录它发给后端的字节。
@MainActor
private final class FocusedTerminal {
    let session = TerminalSession()
    let backend = MockBackend()
    let window: NSWindow
    /// uTerm 的 ⌃↩ 处理接了几次（替程序发了回车）。
    private(set) var intercepted = 0
    /// 交给主菜单试过的 ⌘ 组合。真的主菜单不能用：⌘Q / ⌘W / ⌘N 会真的执行。
    var offeredToMenu: [NSEvent] = []
    /// 假的主菜单接不接。
    var menuTakesEverything = false

    var view: GhosttySurfaceView { session.ghostty.view }

    /// `onScreen`：要 surface 真的解析字节、编码按键时用（透明、在屏上，引擎才有节拍）。
    init(onScreen: Bool) async {
        session.attentionSink = { _ in }
        await session.connect(using: backend)
        let rect = NSRect(x: 0, y: 0, width: 400, height: 300)
        if onScreen {
            window = ProbeWindow.make(contentRect: rect, styleMask: [.titled], contentView: NSView(frame: rect),
                                      placement: .transparentOnScreen)
        } else {
            window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
        }
        let view = session.ghostty.view
        view.frame = rect
        window.contentView?.addSubview(view)
        let original = view.onControlReturn
        view.onControlReturn = { [weak self] in
            let handled = original?() ?? false
            if handled { self?.intercepted += 1 }
            return handled
        }
        view.performMenuKeyEquivalent = { [weak self] event in
            self?.offeredToMenu.append(event)
            return self?.menuTakesEverything ?? false
        }
        window.makeFirstResponder(view)
        if onScreen {
            let deadline = Date().addingTimeInterval(10)
            while !session.ghostty.isLive, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// 后端收到的全部字节。输入经有序通道异步到达：等够 `count` 字节或超时。
    func sent(expecting count: Int, timeout: TimeInterval = 2) async -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let bytes = await backend.writtenData.flatMap { [UInt8]($0) }
            if bytes.count >= count || Date() > deadline { return bytes }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func close() {
        session.dispose()
        window.orderOut(nil)
    }
}
