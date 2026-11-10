import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 接了硬件键盘时，带 ⌘ / ⌥ 的组合交给 GhosttyKit 的按键绑定表之后是什么结果。
///
/// 硬件键（`pressesBegan`）、键盘条、`sendKey` 最后都走 `ghostty_surface_key`，引擎先查绑定表、认下就把这一下吞掉。
/// Ghostty 的默认绑定是给它自己的 App 定的（⌘K 清屏、⌘+ / ⌘- 字号、⌘T / ⌘W / ⌘N / ⌘D 开关标签和分屏……），在 uTerm 里：
/// - ⌘K 只清 surface 的屏：影子终端、远端程序都不知道，画面和影子从此对不上；
/// - ⌘+ / ⌘- 只改这一个终端的字号：和「字号跟宽度走」打架；
/// - 其余的动作 uTerm 里没人接，按键被白白吞掉。
/// 这里用 `sendKey`（不经 `UIKey`，XCTest 造不出真 `UIPress`）走同一个入口，核清掉默认绑定之后的行为——
/// 绑定清单是两端共用的 `TerminalKeyBindings`（Mac 同病，见迁移日志「硬件键盘」）。
@MainActor
final class GhosttyHardwareKeyBindingTests: XCTestCase {
    private func makeHost() async throws -> GhosttyProbeHost {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 500))
        try await host.waitUntilReady()
        host.bridge.inputLog = []
        return host
    }

    /// ⌘K 不清屏：画面上的字还在、和影子终端的可见区一致，也没往远端发东西（legacy 编码下带 ⌘ 的字母编不出字节）。
    func testCommandKDoesNotClearTheSurfaceBehindTheShadow() async throws {
        let host = try await makeHost()
        defer { host.close() }
        host.feedAndWait("first line\r\nsecond line\r\n$ ")
        XCTAssertTrue(host.viewportText.contains("first line"), "喂的字没上屏：\(host.viewportText.prefix(80))")

        host.view.sendKey(GhosttyTerminal.TerminalKey.k, modifiers: .super_)
        try await Task.sleep(for: .milliseconds(150))
        host.bridge.session.waitForPendingOutput()

        XCTAssertTrue(host.viewportText.contains("first line"),
                      "⌘K 被 Ghostty 的默认绑定当成清屏：surface 清了、影子没清：\(host.viewportText.prefix(80))")
        XCTAssertTrue(host.bridge.shadow.viewportText().contains("first line"))
        XCTAssertEqual(host.bridge.inputLog ?? [], [], "⌘K 不该往远端发字节")
    }

    /// ⌘= / ⌘- 不改这个终端的字号（iOS 的字号跟终端宽度走，由容器定）。
    func testCommandPlusMinusDoNotZoomOneTerminal() async throws {
        let host = try await makeHost()
        defer { host.close() }
        let before = try XCTUnwrap(host.view.fontSize)
        host.view.sendKey(GhosttyTerminal.TerminalKey.equal, modifiers: .super_)
        host.view.sendKey(GhosttyTerminal.TerminalKey.equal, modifiers: .super_)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.view.fontSize, before, "⌘= 被 Ghostty 的默认绑定当成放大字号")
        host.view.sendKey(GhosttyTerminal.TerminalKey.minus, modifiers: .super_)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.view.fontSize, before, "⌘- 被 Ghostty 的默认绑定当成缩小字号")
    }

    /// 「自然文本编辑」（两端共用的绑定清单加回来的那几条）：⌥← / ⌥→ 按词移动（`ESC b` / `ESC f`），
    /// ⌘← / ⌘→ 到行首 / 行尾（`^A` / `^E`），⌘⌫ 删到行首（`^U`）。shell 默认的 emacs 键位下不用配就生效。
    func testNaturalTextEditingBindings() async throws {
        let host = try await makeHost()
        defer { host.close() }
        let cases: [(GhosttyTerminal.TerminalKey, TerminalInputModifiers, [UInt8], String)] = [
            (.arrowLeft, .alt, [0x1B, 0x62], "⌥←"),
            (.arrowRight, .alt, [0x1B, 0x66], "⌥→"),
            (.arrowLeft, .super_, [0x01], "⌘←"),
            (.arrowRight, .super_, [0x05], "⌘→"),
            (.backspace, .super_, [0x15], "⌘⌫"),
        ]
        for (key, modifiers, expected, label) in cases {
            host.bridge.inputLog = []
            host.view.sendKey(key, modifiers: modifiers)
            try await Task.sleep(for: .milliseconds(60))
            let sent = (host.bridge.inputLog ?? []).reduce(Data(), +)
            XCTAssertEqual([UInt8](sent), expected, "\(label) 发出去的字节")
        }
    }

    /// 没有绑定接的 ⌘ 组合交给引擎的话，legacy 键盘协议下方向键、回车这类会编成带 super 的序列（shell 不认，留残渣）；
    /// 带 ⌘ 的字母键编不出字节。这是硬件键盘要在视图里丢掉它们的原因（`MGhosttyTerminalView.dropsCommandChord`）；
    /// `sendKey` 不经那道过滤，这里核的是引擎本身。
    func testEngineEncodesUnboundCommandChordsAsResidueInLegacyMode() async throws {
        let host = try await makeHost()
        defer { host.close() }
        let cases: [(GhosttyTerminal.TerminalKey, [UInt8], String)] = [
            (.arrowUp, Array("\u{1B}[1;9A".utf8), "⌘↑"),
            (.enter, Array("\u{1B}[27;9;13~".utf8), "⌘↩"),
            (.j, [], "⌘J"),
            (.t, [], "⌘T"),
            (.digit1, [], "⌘1"),
        ]
        for (key, expected, label) in cases {
            host.bridge.inputLog = []
            host.view.sendKey(key, modifiers: .super_)
            try await Task.sleep(for: .milliseconds(60))
            let sent = (host.bridge.inputLog ?? []).reduce(Data(), +)
            XCTAssertEqual([UInt8](sent), expected, "\(label) 交给引擎后发出去的字节")
        }
    }

    /// 硬件键盘的过滤：legacy 协议下没有绑定接的 ⌘ 组合丢掉；绑定（⌘← / ⌘C / ⌘⌫）照常交给引擎；不带 ⌘ 的不管；
    /// 程序开了 kitty 键盘协议就一律照发。`UIPress` 造不出来，核的是 `pressesBegan` 用的那个判断。
    func testHardwareCommandChordsAreDroppedUnlessBoundOrKittyProtocol() async throws {
        let host = try await makeHost()
        defer { host.close() }
        typealias HID = UIKeyboardHIDUsage
        func drops(_ usage: HID, _ flags: UIKeyModifierFlags, _ text: String) -> Bool {
            host.view.dropsCommandChord(usage: UInt16(usage.rawValue), modifierFlags: flags, charactersIgnoringModifiers: text)
        }
        XCTAssertTrue(drops(.keyboardUpArrow, [.command, .numericPad], UIKeyCommand.inputUpArrow), "⌘↑")
        XCTAssertTrue(drops(.keyboardReturnOrEnter, .command, "\r"), "⌘↩")
        XCTAssertTrue(drops(.keyboardJ, .command, "j"), "⌘J")
        XCTAssertFalse(drops(.keyboardLeftArrow, [.command, .numericPad], UIKeyCommand.inputLeftArrow), "⌘← 是绑定")
        XCTAssertFalse(drops(.keyboardC, .command, "c"), "⌘C 是绑定")
        XCTAssertFalse(drops(.keyboardDeleteOrBackspace, .command, "\u{8}"), "⌘⌫ 是绑定")
        XCTAssertFalse(drops(.keyboardUpArrow, .numericPad, UIKeyCommand.inputUpArrow), "不带 ⌘ 的不管")
        XCTAssertFalse(drops(.keyboardUpArrow, [.alternate, .numericPad], UIKeyCommand.inputUpArrow))

        // 程序开 kitty 键盘协议（push flags 1）：⌘ 组合照发。
        host.feedAndWait("\u{1B}[>1u")
        XCTAssertEqual(host.bridge.shadow.kittyKeyboardFlags, 1)
        XCTAssertFalse(drops(.keyboardUpArrow, [.command, .numericPad], UIKeyCommand.inputUpArrow), "kitty 协议下 ⌘↑ 照发")
        host.feedAndWait("\u{1B}[<u")
        XCTAssertTrue(drops(.keyboardUpArrow, [.command, .numericPad], UIKeyCommand.inputUpArrow), "退出 kitty 协议后又丢")
    }

    /// 清掉默认绑定不该连普通按键一起清掉：⌃C、回车、方向键照常编码。
    func testOrdinaryKeysStillEncode() async throws {
        let host = try await makeHost()
        defer { host.close() }
        let cases: [(GhosttyTerminal.TerminalKey, TerminalInputModifiers, [UInt8], String)] = [
            (.c, .ctrl, [0x03], "⌃C"),
            (.enter, [], [0x0D], "回车"),
            (.arrowUp, [], [0x1B, 0x5B, 0x41], "↑"),
        ]
        for (key, modifiers, expected, label) in cases {
            host.bridge.inputLog = []
            host.view.sendKey(key, modifiers: modifiers)
            try await Task.sleep(for: .milliseconds(60))
            let sent = (host.bridge.inputLog ?? []).reduce(Data(), +)
            XCTAssertEqual([UInt8](sent), expected, "\(label) 发出去的字节")
        }
    }
}
