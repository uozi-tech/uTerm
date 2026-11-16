import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// GhosttyKit spike：输入这一侧在 uTerm 本地能做到什么（docs/ghostty-eval/ios-spike.md）。
/// 对应旧引擎的本地补丁 #2（键盘类型可写）、#8（组字可见 + 候选框跟着光标），以及键盘条 / 粘滞修饰 / 硬件键盘。
@MainActor
final class GhosttySpikeInputTests: XCTestCase {
    private func ready() async throws -> GhosttyProbeHost {
        let host = try GhosttyProbeHost()
        host.window.makeKey()
        try await host.waitUntilReady()
        host.bridge.inputLog = []
        return host
    }

    private func pump(_ seconds: TimeInterval = 0.15) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    /// write 回调是跳回主线程再记的：等一下再读。
    private func sent(_ host: GhosttyProbeHost) async throws -> [UInt8] {
        try await pump(0.05)
        return host.bridge.inputLog?.flatMap { [UInt8]($0) } ?? []
    }

    private func clear(_ host: GhosttyProbeHost) { host.bridge.inputLog = [] }

    // MARK: 补丁 #2：键盘类型

    /// 上游 `keyboardType` 的 getter 恒为 `.default`、setter 是空实现；子类覆写后可写，UIKit（走 ObjC 读 traits）也读得到。
    func testKeyboardTypeCanBeForcedLocally() async throws {
        let host = try await ready()
        defer { host.close() }

        let stock = UITerminalView(frame: .zero)
        stock.keyboardType = .asciiCapable
        XCTAssertEqual(stock.keyboardType, .default, "自证：上游视图改不动键盘类型")

        host.view.keyboardType = .asciiCapable
        XCTAssertEqual(host.view.keyboardType, .asciiCapable)
        let traits: any UITextInputTraits = host.view
        XCTAssertEqual(traits.keyboardType, .asciiCapable, "协议见证也走覆写")
        XCTAssertEqual(host.view.value(forKey: "keyboardType") as? Int, UIKeyboardType.asciiCapable.rawValue,
                       "UIKit 按 ObjC 读 traits 时也拿到 .asciiCapable")
    }

    /// 默认英文（`MGhosttyTerminalView.textInputMode`，和换引擎之前同一套规则）。
    func testInputModeDefaultsToEnglish() async throws {
        guard UITextInputMode.activeInputModes.contains(where: { $0.primaryLanguage?.hasPrefix("en") == true }) else {
            throw XCTSkip("模拟器没开英文键盘")
        }
        let host = try await ready()
        defer { host.close() }
        XCTAssertEqual(host.view.textInputMode?.primaryLanguage?.hasPrefix("en"), true)
    }

    // MARK: 补丁 #8：组字可见、候选框跟着光标

    /// 光标挪到第 6 行第 11 列再组字：候选框的锚点（`firstRect` / `caretRect`）落在光标格子上，不是整个视图；
    /// 组字中的文字画进终端（光标那一行的像素变了）；上屏后字发给远端。
    func testMarkedTextDrawsAtCursorAndAnchorsCandidates() async throws {
        let host = try await ready()
        defer { host.close() }
        host.feedAndWait("\u{1B}[2J\u{1B}[6;11H")
        XCTAssertTrue(host.view.becomeFirstResponder())
        try await pump(0.3)
        let cols = CGFloat(host.grid.cols), rows = CGFloat(host.grid.rows)
        let cellW = host.view.bounds.width / cols, cellH = host.view.bounds.height / rows
        let before = rowPixels(host, rowMinY: 5 * cellH, height: cellH)
        let fullBefore = rowPixels(host, rowMinY: 0, height: host.view.bounds.height)

        host.view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        try await pump(0.3)
        let range = try XCTUnwrap(host.view.markedTextRange, "进入组字")
        XCTAssertEqual(host.view.text(in: range), "ni")
        let anchor = host.view.firstRect(for: range)
        let caret = host.view.caretRect(for: range.end)
        print("SPIKE ime anchor=\(anchor) caret=\(caret) cell=\(cellW)x\(cellH) bounds=\(host.view.bounds)")
        XCTAssertNotEqual(anchor, host.view.bounds, "候选框锚点不该是整个视图（旧引擎上游版本的毛病）")
        // Ghostty 的窗口有内边距，允许差一格。
        XCTAssertEqual(anchor.minY, 5 * cellH, accuracy: cellH * 1.2, "锚点在光标那一行")
        XCTAssertEqual(anchor.minX, 10 * cellW, accuracy: cellW * 1.5, "锚点从光标那一列开始")
        XCTAssertGreaterThan(caret.minX, anchor.minX, "组字里的插入点在拼音之后")
        let bytes1 = try await sent(host)
        XCTAssertEqual(bytes1, [], "组字期间什么都不发")

        let during = rowPixels(host, rowMinY: 5 * cellH, height: cellH)
        XCTAssertGreaterThan(differingFraction(before, during), 0.005, "组字中的文字要画进终端")
        // 组字实际画在哪儿（前后两张整屏截图里变了的像素框），和候选框锚点比。
        let fullDuring = rowPixels(host, rowMinY: 0, height: host.view.bounds.height)
        let drawn = changedBox(fullBefore, fullDuring, width: host.view.bounds.width, height: host.view.bounds.height)
        print("SPIKE ime drawn-preedit=\(drawn) anchor=\(anchor)")
        if let drawn {
            XCTAssertEqual(anchor.midY, drawn.midY, accuracy: cellH * 0.6, "候选框锚点和画出来的组字在同一行")
            XCTAssertEqual(anchor.minX, drawn.minX, accuracy: cellW * 1.2, "候选框锚点和画出来的组字左对齐")
        }

        host.view.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
        host.view.unmarkText()
        try await pump(0.2)
        XCTAssertNil(host.view.markedTextRange)
        let bytes2 = String(decoding: try await sent(host), as: UTF8.self)
        XCTAssertEqual(bytes2, "你", "上屏的字发给远端")
    }

    /// 走系统自己的拼音引擎（同 `RemoteKeyInputRealKeyboardTests`）：要模拟器开了中文键盘，没开就跳过。
    func testRealPinyinEngine() async throws {
        guard let chinese = UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage?.hasPrefix("zh") == true }) else {
            throw XCTSkip("模拟器没开中文键盘")
        }
        let host = try await ready()
        defer { host.close() }
        XCTAssertTrue(host.view.becomeFirstResponder())
        try await pump(0.4)
        let cls = try XCTUnwrap(NSClassFromString("UIKeyboardInputModeController") as AnyObject as? NSObject)
        let controller = try XCTUnwrap(cls.perform(NSSelectorFromString("sharedInputModeController"))?.takeUnretainedValue() as? NSObject)
        controller.setValue(chinese, forKey: "currentInputMode")
        try await pump(0.4)
        XCTAssertEqual(host.view.textInputMode?.primaryLanguage, chinese.primaryLanguage, "切过之后记住用户选的")

        let implClass = try XCTUnwrap(NSClassFromString("UIKeyboardImpl") as AnyObject as? NSObject)
        let impl = try XCTUnwrap(implClass.perform(NSSelectorFromString("activeInstance"))?.takeUnretainedValue() as? NSObject)
        let add = NSSelectorFromString("addInputString:")
        try XCTSkipUnless(impl.responds(to: add), "这个系统版本没有 addInputString:")
        clear(host)
        for letter in ["n", "i"] {
            impl.perform(add, with: letter)
            try await pump(0.6)
        }
        XCTAssertEqual(host.view.markedTextRange.flatMap { host.view.text(in: $0) }, "ni", "真实拼音引擎进入组字")
        let bytes3 = try await sent(host)
        XCTAssertEqual(bytes3, [], "组字期间什么都不发")
        impl.perform(add, with: " ")
        try await pump(0.6)
        XCTAssertNil(host.view.markedTextRange)
        let typed = String(decoding: try await sent(host), as: UTF8.self)
        print("SPIKE pinyin typed=\(typed)")
        XCTAssertFalse(typed.isEmpty)
        XCTAssertFalse(typed.allSatisfy(\.isASCII), "发出去的是汉字，不是拼音：\(typed)")
    }

    // MARK: 键盘条

    /// 键盘条的键走 GhosttyKit 的按键路径：由终端按当前模式编码。普通模式与旧引擎那条路径发的一样；
    /// 程序开了 DECCKM（vim、less）时方向键变成 SS3（`ESC O A`）——今天的键盘条固定发 `ESC [ A`。
    func testKeyBarKeysAreEncodedByTheTerminal() async throws {
        let host = try await ready()
        defer { host.close() }
        func press(_ key: uTermMobile.TerminalKey) async throws -> String {
            clear(host)
            host.bridge.send(key)
            return String(decoding: try await sent(host), as: UTF8.self)
        }
        for key in TerminalKeyCatalog.arrows + TerminalKeyCatalog.leading + TerminalKeyCatalog.trailing + TerminalKeyCatalog.function
            + TerminalKeyCatalog.control {
            let bytes = try await press(key)
            XCTAssertEqual(bytes, key.send, "\(key.label) 普通模式下与今天的键盘条一致")
        }
        var navigation: [String: String] = [:]
        for key in TerminalKeyCatalog.navigation { navigation[key.label] = try await press(key) }
        print("SPIKE keybar navigation=\(navigation.mapValues { $0.unicodeScalars.map { String(format: "%02X", $0.value) }.joined(separator: " ") })")

        host.feedAndWait("\u{1B}[?1h")
        let up = try await press(TerminalKeyCatalog.arrows[1])
        XCTAssertEqual(up, "\u{1B}OA", "DECCKM 下方向键由终端编码成 SS3")
        host.feedAndWait("\u{1B}[?1l")

        for key in TerminalKeyCatalog.symbols {
            let bytes = try await press(key)
            XCTAssertEqual(bytes, key.send, "符号 \(key.label) 照原样发，不被括号粘贴包起来")
        }
    }

    /// 粘滞 Ctrl / Alt：GhosttyKit 原生。上膛 → 软键盘下一个字符带修饰 → 自动复位、通知变化。
    func testStickyModifiersApplyToTheNextCharacter() async throws {
        let host = try await ready()
        defer { host.close() }
        XCTAssertTrue(host.view.becomeFirstResponder())
        try await pump(0.2)
        var changes = 0
        host.view.setStickyModifierChangeHandler { changes += 1 }

        host.bridge.toggleSticky(.ctrl)
        XCTAssertEqual(host.view.stickyActivation(for: .ctrl), .armed)
        clear(host)
        host.view.insertText("c")
        let bytes4 = try await sent(host)
        XCTAssertEqual(bytes4, [0x03], "Ctrl+C")
        XCTAssertEqual(host.view.stickyActivation(for: .ctrl), .inactive, "用过一次就复位")

        host.bridge.toggleSticky(.alt)
        clear(host)
        host.view.insertText("f")
        let bytes5 = try await sent(host)
        XCTAssertEqual(bytes5, [0x1B, 0x66], "Alt+f = ESC f")
        XCTAssertEqual(host.view.stickyActivation(for: .alt), .inactive)

        // 键盘条的方向键也吃粘滞修饰（今天的键盘条是先清掉修饰再发）。
        host.bridge.toggleSticky(.ctrl)
        clear(host)
        host.bridge.send(TerminalKeyCatalog.arrows[0])
        let ctrlLeft = String(decoding: try await sent(host), as: UTF8.self)
        print("SPIKE sticky ctrl+left=\(ctrlLeft.unicodeScalars.map { String(format: "%02X", $0.value) })")
        XCTAssertEqual(ctrlLeft, "\u{1B}[1;5D", "Ctrl+← 按 xterm 修饰键编码")
        XCTAssertGreaterThan(changes, 3, "粘滞状态变化有回调，键盘条据此亮灭")
    }

    /// 硬件键盘：Ctrl+字母与 Esc 走 `UIKeyCommand`（可以直接调它的 action 验证）；方向键等走 `pressesBegan`，
    /// `UIPress` / `UIKey` 没有公开构造器，XCTest 里造不出来，留给真机。
    func testHardwareKeyCommandsReachTheTerminal() async throws {
        let host = try await ready()
        defer { host.close() }
        XCTAssertTrue(host.view.becomeFirstResponder())
        try await pump(0.2)
        let commands = host.view.keyCommands ?? []
        let ctrlC = try XCTUnwrap(commands.first { $0.input == "c" && $0.modifierFlags == .control })
        let escape = try XCTUnwrap(commands.first { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty })
        clear(host)
        host.view.perform(ctrlC.action, with: ctrlC)
        let bytes6 = try await sent(host)
        XCTAssertEqual(bytes6, [0x03])
        try await pump(0.05)
        clear(host)
        host.view.perform(escape.action, with: escape)
        let bytes7 = try await sent(host)
        XCTAssertEqual(bytes7, [0x1B])
    }

    // MARK: 跟随底部（补丁 #17 的场景）

    /// 贴底时新输出跟着走；往上翻了之后新输出不把视口拽回去。GhosttyKit 没有 UIScrollView、没有惯性回弹可抢。
    func testFollowsBottomOnlyWhenAtBottom() async throws {
        let host = try await ready()
        defer { host.close() }
        host.feedAndWait(TerminalSpikeCorpus.history(lines: 300, cols: host.grid.cols))
        try await pump(0.2)
        let atBottom = try XCTUnwrap(host.scrollbar)
        XCTAssertEqual(atBottom.offset + atBottom.len, atBottom.total, "初始贴底")

        host.feedAndWait(TerminalSpikeCorpus.history(lines: 20, cols: host.grid.cols))
        try await pump(0.2)
        let followed = try XCTUnwrap(host.scrollbar)
        XCTAssertEqual(followed.offset + followed.len, followed.total, "贴底时跟着新输出走")

        let scale = Double(host.view.window?.screen.nativeScale ?? 3)
        host.view.sendMouseScroll(x: 0, y: Double(host.view.bounds.height) * scale)
        try await pump(0.2)
        let scrolled = try XCTUnwrap(host.scrollbar)
        XCTAssertLessThan(scrolled.offset + scrolled.len, scrolled.total, "往上翻了")

        host.feedAndWait(TerminalSpikeCorpus.history(lines: 20, cols: host.grid.cols))
        try await pump(0.2)
        let after = try XCTUnwrap(host.scrollbar)
        print("SPIKE follow bottom=\(atBottom) followed=\(followed) scrolled=\(scrolled) after-output=\(after)")
        XCTAssertLessThan(after.offset + after.len, after.total, "往上翻着时新输出不把视口拽回底部")

        // 打字回到底部（Ghostty 默认 scroll-to-bottom = keystroke）。
        host.view.insertText("x")
        try await pump(0.2)
        let typed = try XCTUnwrap(host.scrollbar)
        XCTAssertEqual(typed.offset + typed.len, typed.total, "打字回到底部")
    }

    // MARK: 工具

    private func rowPixels(_ host: GhosttyProbeHost, rowMinY: CGFloat, height: CGFloat) -> [UInt8] {
        let rect = CGRect(x: 0, y: rowMinY, width: host.view.bounds.width, height: height)
        let renderer = UIGraphicsImageRenderer(bounds: rect)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        // 重画进一块紧凑的 RGBA 位图：渲染器给的位图每行可能有对齐填充，直接读会错列。
        guard let cg = image.cgImage else { return [] }
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard let context = CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return pixels
    }

    /// 两张截图（视图坐标、按屏幕倍率出的位图）里变了的像素外框，换回点。
    private func changedBox(_ a: [UInt8], _ b: [UInt8], width: CGFloat, height: CGFloat) -> CGRect? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let pixels = a.count / 4
        let scale = (Double(pixels) / Double(width * height)).squareRoot()
        let w = Int((Double(width) * scale).rounded())
        guard w > 0 else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for index in 0..<pixels where abs(Int(a[index * 4]) - Int(b[index * 4])) > 24
            || abs(Int(a[index * 4 + 1]) - Int(b[index * 4 + 1])) > 24 {
            let x = index % w, y = index / w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                      width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
    }

    private func differingFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var differing = 0
        for index in stride(from: 0, to: a.count, by: 4) where abs(Int(a[index]) - Int(b[index])) > 24 {
            differing += 1
        }
        return Double(differing) / Double(a.count / 4)
    }
}
