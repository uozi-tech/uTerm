import AppKit
import Carbon.HIToolbox
import GhosttyTerminal
import XCTest
@testable import uTerm

/// 终端有焦点时，每个带修饰键的组合去了哪儿：uTerm 的菜单 / 快捷键、终端自己的动作（拷贝、粘贴、翻回滚），
/// 还是按终端的规矩编成字节发给程序。用真的 `NSEvent` 走窗口的分发顺序（`performKeyEquivalent` → `sendEvent`），
/// 读后端收到的字节。
@MainActor
final class TerminalKeyBindingTests: XCTestCase {

    private var rig: GhosttySurfaceRig!

    override func setUp() async throws {
        try await super.setUp()
        rig = await GhosttySurfaceRig()
    }

    override func tearDown() async throws {
        rig?.close()
        rig = nil
        try await super.tearDown()
    }

    struct Chord {
        let name: String
        let characters: String
        let ignoring: String
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags

        init(_ name: String, _ characters: String, ignoring: String? = nil, _ keyCode: Int,
             _ modifiers: NSEvent.ModifierFlags) {
            self.name = name
            self.characters = characters
            self.ignoring = ignoring ?? characters
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    private static let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]
    private static let left = "\u{F702}", right = "\u{F703}", up = "\u{F700}", down = "\u{F701}"
    private static let home = "\u{F729}", end = "\u{F72B}", pageUp = "\u{F72C}", pageDown = "\u{F72D}"

    static let chords: [Chord] = [
        Chord("⌥←", left, kVK_LeftArrow, arrowFlags.union(.option)),
        Chord("⌥→", right, kVK_RightArrow, arrowFlags.union(.option)),
        Chord("⌥⌫", "\u{7F}", kVK_Delete, .option),
        Chord("⌥b", "∫", ignoring: "b", kVK_ANSI_B, .option),
        Chord("⌥f", "ƒ", ignoring: "f", kVK_ANSI_F, .option),
        Chord("⌥d", "∂", ignoring: "d", kVK_ANSI_D, .option),
        Chord("⌥.", "≥", ignoring: ".", kVK_ANSI_Period, .option),
        Chord("⌘←", left, kVK_LeftArrow, arrowFlags.union(.command)),
        Chord("⌘→", right, kVK_RightArrow, arrowFlags.union(.command)),
        Chord("⌘↑", up, kVK_UpArrow, arrowFlags.union(.command)),
        Chord("⌘↓", down, kVK_DownArrow, arrowFlags.union(.command)),
        Chord("⌘⌫", "\u{7F}", kVK_Delete, .command),
        Chord("⌃←", left, kVK_LeftArrow, arrowFlags.union(.control)),
        Chord("⌃→", right, kVK_RightArrow, arrowFlags.union(.control)),
        Chord("⇧←", left, kVK_LeftArrow, arrowFlags.union(.shift)),
        Chord("⇧→", right, kVK_RightArrow, arrowFlags.union(.shift)),
        Chord("⌘↩", "\r", kVK_Return, .command),
        Chord("⌘⇧↩", "\r", kVK_Return, [.command, .shift]),
        Chord("⌘K", "k", kVK_ANSI_K, .command),
        Chord("⌘T", "t", kVK_ANSI_T, .command),
        Chord("⌘N", "n", kVK_ANSI_N, .command),
        Chord("⌘D", "d", kVK_ANSI_D, .command),
        Chord("⌘⇧D", "D", ignoring: "d", kVK_ANSI_D, [.command, .shift]),
        Chord("⌘F", "f", kVK_ANSI_F, .command),
        Chord("⌘G", "g", kVK_ANSI_G, .command),
        Chord("⌘E", "e", kVK_ANSI_E, .command),
        Chord("⌘J", "j", kVK_ANSI_J, .command),
        Chord("⌘Z", "z", kVK_ANSI_Z, .command),
        Chord("⌘=", "=", kVK_ANSI_Equal, .command),
        Chord("⌘-", "-", kVK_ANSI_Minus, .command),
        Chord("⌘0", "0", kVK_ANSI_0, .command),
        Chord("⌘1", "1", kVK_ANSI_1, .command),
        Chord("⌘[", "[", kVK_ANSI_LeftBracket, .command),
        Chord("⌘]", "]", kVK_ANSI_RightBracket, .command),
        Chord("⌘⇧[", "{", ignoring: "[", kVK_ANSI_LeftBracket, [.command, .shift]),
        Chord("⌘⇧P", "P", ignoring: "p", kVK_ANSI_P, [.command, .shift]),
        Chord("⌘⌥←", left, kVK_LeftArrow, arrowFlags.union([.command, .option])),
        Chord("⌘⌥I", "ˆ", ignoring: "i", kVK_ANSI_I, [.command, .option]),
        Chord("⌘⌃F", "\u{06}", ignoring: "f", kVK_ANSI_F, [.command, .control]),
        Chord("⌃Tab", "\t", kVK_Tab, .control),
        Chord("⌃⇧Tab", "\u{19}", ignoring: "\t", kVK_Tab, [.control, .shift]),
        Chord("⌘Home", home, kVK_Home, [.function, .command]),
        Chord("⌘End", end, kVK_End, [.function, .command]),
        Chord("⌘PageUp", pageUp, kVK_PageUp, [.function, .command]),
        Chord("⌘PageDown", pageDown, kVK_PageDown, [.function, .command]),
        Chord("PageUp", pageUp, kVK_PageUp, .function),
        Chord("PageDown", pageDown, kVK_PageDown, .function),
        Chord("⇧PageUp", pageUp, kVK_PageUp, [.function, .shift]),
        Chord("Home", home, kVK_Home, .function),
        Chord("End", end, kVK_End, .function),
        Chord("←", left, kVK_LeftArrow, arrowFlags),
        Chord("⌃C", "\u{03}", ignoring: "c", kVK_ANSI_C, .control),
        Chord("Esc", "\u{1B}", kVK_Escape, []),
    ]

    /// 按一下，返回（key equivalent 这一段有没有人接、后端新收到的字节）。
    private func press(_ chord: Chord) async -> (handled: Bool, bytes: [UInt8]) {
        let before = await rig.sent(expecting: 0, timeout: 0).count
        let handled = RealEvents.press(window: rig.window, characters: chord.characters, ignoring: chord.ignoring,
                                       keyCode: chord.keyCode, modifiers: chord.modifiers)
        // 没有字节的组合要等到超时才知道「确实没有」；有字节的一到就返回。
        let all = await rig.sent(expecting: before + 1, timeout: 0.25)
        return (handled, Array(all.dropFirst(before)))
    }

    private func chord(_ name: String) -> Chord {
        guard let found = Self.chords.first(where: { $0.name == name }) else { fatalError("没有这个组合：\(name)") }
        return found
    }

    private static func describe(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "（无）" }
        return bytes.map { byte in
            switch byte {
            case 0x1B: return "ESC"
            case 0x20...0x7E: return String(UnicodeScalar(byte))
            default: return String(format: "\\x%02X", byte)
            }
        }.joined(separator: " ")
    }

    /// 期望：组合名 → 发给程序的字节（`nil` = 一个字节都不发）。`binding` 列出的组合由终端自己的绑定接
    /// （key equivalent 这一段返回 true），其余的一律不在 key equivalent 这一段被认下——菜单因此轮得到它们。
    private func check(_ expected: [(String, String?)], bindings: Set<String>, mode: String,
                       file: StaticString = #filePath, line: UInt = #line) async {
        for (name, bytes) in expected {
            let result = await press(chord(name))
            let want = bytes.map { Array($0.utf8) } ?? []
            XCTAssertEqual(Self.describe(result.bytes), Self.describe(want), "\(mode) \(name) 发给程序的字节", file: file, line: line)
            XCTAssertEqual(result.handled, bindings.contains(name),
                           "\(mode) \(name) \(bindings.contains(name) ? "应当由终端的绑定接" : "不该在 key equivalent 这一段被终端认下")",
                           file: file, line: line)
        }
    }

    private static let esc = "\u{1b}"

    /// legacy 键盘模式（shell、多数程序）：⌥ 当 Meta、⌥← / ⌥→ 按词移动、⌘← / ⌘→ / ⌘⌫ 是行首 / 行尾 / 删到行首，
    /// 方向键与功能键照常编码；Ghostty 的默认绑定（⌘K 清屏、⌘T、⌘D、⌘↩ 全屏……）全清，没有菜单接的 ⌘ 组合一个字节都不发。
    /// ⌘F / ⌘G 由 uTerm 自己的查找栏接（`GhosttySurfaceView.findCommand`），⌘E 没有选区时不接。
    func testLegacyModeRouting() async {
        let e = Self.esc
        await check([
            ("⌥←", "\(e)b"), ("⌥→", "\(e)f"), ("⌥⌫", "\(e)\u{7F}"),
            ("⌥b", "\(e)b"), ("⌥f", "\(e)f"), ("⌥d", "\(e)d"), ("⌥.", "\(e)."),
            ("⌘←", "\u{01}"), ("⌘→", "\u{05}"), ("⌘⌫", "\u{15}"),
            ("⌘↑", nil), ("⌘↓", nil), ("⌘↩", nil), ("⌘⇧↩", nil),
            ("⌘K", nil), ("⌘T", nil), ("⌘N", nil), ("⌘D", nil), ("⌘⇧D", nil), ("⌘F", nil), ("⌘G", nil),
            ("⌘E", nil), ("⌘J", nil), ("⌘Z", "\u{1F}"), ("⌘=", nil), ("⌘-", nil), ("⌘0", nil), ("⌘1", nil),
            ("⌘[", nil), ("⌘]", nil), ("⌘⇧[", nil), ("⌘⇧P", nil), ("⌘⌥←", nil), ("⌘⌥I", nil), ("⌘⌃F", nil),
            ("⌃←", "\(e)[1;5D"), ("⌃→", "\(e)[1;5C"), ("⇧←", "\(e)[1;2D"), ("⇧→", "\(e)[1;2C"),
            ("⌘Home", nil), ("⌘End", nil), ("⌘PageUp", nil), ("⌘PageDown", nil),
            ("⇧PageUp", "\(e)[5;2~"), ("Home", "\(e)[H"), ("End", "\(e)[F"), ("←", "\(e)[D"),
            ("⌃C", "\u{03}"), ("Esc", e),
        ], bindings: ["⌘←", "⌘→", "⌘⌫", "⌘Z", "⌘Home", "⌘End", "⌘PageUp", "⌘PageDown", "⌘F", "⌘G"], mode: "legacy")
    }

    /// kitty 键盘协议（Claude Code 这类程序会开）：没有绑定的 ⌘ 组合按协议编码交给程序；
    /// 方向键不带 Num Lock（macOS 给方向键带 `.numericPad`，引擎原样会编成 `CSI 1;129D`，见本地包补丁）。
    func testKittyModeRouting() async {
        let e = Self.esc
        await rig.feed("\(e)[>1u")
        XCTAssertEqual(rig.session.shadow.kittyKeyboardFlags, 1)
        await check([
            ("⌥←", "\(e)b"), ("⌥→", "\(e)f"),
            ("⌘←", "\u{01}"), ("⌘⌫", "\u{15}"), ("⌘Z", "\u{1F}"),
            ("⌘↩", "\(e)[13;9u"), ("⌘K", "\(e)[107;9u"), ("⌘T", "\(e)[116;9u"), ("⌘↑", "\(e)[1;9A"),
            ("←", "\(e)[D"), ("PageUp", "\(e)[5~"), ("PageDown", "\(e)[6~"),
            ("⌘Home", nil), ("⌃C", "\(e)[99;5u"), ("Esc", "\(e)[27u"),
        ], bindings: ["⌘←", "⌘⌫", "⌘Z", "⌘Home"], mode: "kitty")
    }

    /// PageUp / PageDown 不带修饰键：停在 shell 提示符上翻一页回滚、不发给程序；程序开了应用光标键或在备用屏上时发给程序。
    func testPageKeysScrollAtThePromptAndReachFullScreenPrograms() async {
        let e = Self.esc
        await rig.feed((1...200).map { "line \($0)" }.joined(separator: "\r\n"))
        let bottom = rig.surfaceText
        let up = await press(chord("PageUp"))
        XCTAssertEqual(Self.describe(up.bytes), Self.describe([]), "提示符上 PageUp 不发给程序")
        let scrolled = await rig.waitUntil(2) { self.rig.surfaceText != bottom }
        XCTAssertTrue(scrolled, "PageUp 应当翻回滚")
        let down = await press(chord("PageDown"))
        XCTAssertEqual(Self.describe(down.bytes), Self.describe([]))
        let back = await rig.waitUntil(2) { self.rig.surfaceText == bottom }
        XCTAssertTrue(back, "PageDown 应当翻回底部")

        await rig.feed("\(e)[?1h")
        let app = await press(chord("PageUp"))
        XCTAssertEqual(Self.describe(app.bytes), Self.describe(Array("\(e)[5~".utf8)), "应用光标键下 PageUp 发给程序")
        await rig.feed("\(e)[?1l\(e)[?1049h")
        let alt = await press(chord("PageDown"))
        XCTAssertEqual(Self.describe(alt.bytes), Self.describe(Array("\(e)[6~".utf8)), "备用屏上 PageDown 发给程序")
    }

    /// 「编辑 ▸ 撤销」（⌘Z 平时走的那条路）：终端有焦点时撤销的是程序里的编辑——Claude Code 输入框里选中删掉一段，
    /// ⌘Z 要能撤回来。菜单的 `undo:` 沿响应链先到终端视图，发 `^_`，不落到窗口的 undoManager。
    func testEditMenuUndoSendsControlUnderscore() async {
        let before = await rig.sent(expecting: 0, timeout: 0).count
        XCTAssertTrue(rig.window.firstResponder === rig.view)
        XCTAssertTrue(rig.view.tryToPerform(Selector(("undo:")), with: nil), "撤销应当由终端视图接")
        let all = await rig.sent(expecting: before + 1)
        XCTAssertEqual(Self.describe(Array(all.dropFirst(before))), Self.describe([0x1F]))
    }

    /// ⌘A 由终端的绑定全选（没有菜单接时）。
    func testSelectAllBinding() async {
        await rig.feed("hello world")
        XCTAssertNil(rig.selection)
        let result = await press(Chord("⌘A", "a", kVK_ANSI_A, .command))
        XCTAssertTrue(result.handled)
        XCTAssertEqual(result.bytes, [])
        let selected = await rig.waitUntil(2) { self.rig.selection != nil }
        XCTAssertTrue(selected, "⌘A 应当全选")
    }

    /// 绑定表的形状：`keybind = clear` 必须在最前（后面加回去的才不会被它清掉），⌥ 一律当 Alt。
    func testBindingTableClearsDefaultsFirst() {
        let table = TerminalKeyBindings.ghosttyConfiguration
        XCTAssertEqual(table.first?.key, "keybind")
        XCTAssertEqual(table.first?.value, "clear")
        XCTAssertEqual(table.filter { $0.value == "clear" }.count, 1)
        XCTAssertTrue(table.contains { $0.key == "macos-option-as-alt" && $0.value == "true" })
        let rendered = GhosttyTerminalConfig.base(settings: TerminalSettings.read()).rendered
        XCTAssertTrue(rendered.contains("keybind = clear"), "Mac 的配置里要带上绑定表")
    }
}
