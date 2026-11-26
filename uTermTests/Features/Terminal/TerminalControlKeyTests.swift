import AppKit
import Carbon.HIToolbox
import GhosttyTerminal
import XCTest
@testable import uTerm

/// ⌃ + 字母发给程序的字节：legacy、kitty 键盘协议（Claude Code 开的是 `CSI > 5 u`，再加 modifyOtherKeys 2）、
/// 只开 modifyOtherKeys。按 Cocoa 的按键绑定分两类各取两个：有绑定的（⌃A `moveToBeginningOfParagraph:`）、
/// 没有绑定的（⌃C、⌃S、⌃X）。用真的 `NSEvent` 走窗口的分发顺序，读后端收到的字节。
@MainActor
final class TerminalControlKeyTests: XCTestCase {

    private var rig: GhosttySurfaceRig!

    override func setUp() async throws {
        try await super.setUp()
        rig = await GhosttySurfaceRig()
        // 用例直接调视图的 `mouseMoved` 摆指针；用户真鼠标的移动会变成发给程序的鼠标上报，挡掉。
        (rig.window as? ProbeWindow.Unconstrained)?.dropsUserPointerMotion = true
    }

    override func tearDown() async throws {
        rig?.close()
        rig = nil
        try await super.tearDown()
    }

    private struct Key {
        let letter: Character
        let keyCode: Int
        var control: String { String(UnicodeScalar(UInt8(letter.asciiValue! & 0x1F))) }
        var codepoint: Int { Int(letter.asciiValue!) }
    }

    private static let keys: [Key] = [
        Key(letter: "a", keyCode: kVK_ANSI_A), Key(letter: "c", keyCode: kVK_ANSI_C),
        Key(letter: "s", keyCode: kVK_ANSI_S), Key(letter: "x", keyCode: kVK_ANSI_X),
    ]

    private static let esc = "\u{1b}"

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

    /// 按一下 ⌃ + 字母，返回后端新收到的字节。
    private func pressControl(_ key: Key) async -> [UInt8] {
        let before = await rig.sent(expecting: 0, timeout: 0).count
        RealEvents.press(window: rig.window, characters: key.control, ignoring: String(key.letter),
                         keyCode: key.keyCode, modifiers: .control)
        let all = await rig.sent(expecting: before + 1, timeout: 0.5)
        return Array(all.dropFirst(before))
    }

    private func check(mode: String, _ expected: (Key) -> String, file: StaticString = #filePath, line: UInt = #line) async {
        for key in Self.keys {
            let bytes = await pressControl(key)
            print("[control-key] \(mode) ⌃\(key.letter.uppercased()) → \(Self.describe(bytes))")
            XCTAssertEqual(Self.describe(bytes), Self.describe(Array(expected(key).utf8)),
                           "\(mode) ⌃\(key.letter.uppercased()) 发给程序的字节", file: file, line: line)
        }
    }

    /// legacy（shell、没开任何协议的程序）：C0 字节。
    func testLegacyModeSendsC0() async {
        await check(mode: "legacy") { $0.control }
    }

    /// kitty 键盘协议，只有 disambiguate（`CSI > 1 u`）。
    func testKittyDisambiguate() async {
        await rig.feed("\(Self.esc)[>1u")
        XCTAssertEqual(rig.session.shadow.kittyKeyboardFlags, 1)
        await check(mode: "kitty 1") { "\(Self.esc)[\($0.codepoint);5u" }
    }

    /// Claude Code 2.1.x 进输入界面时发的那一串：`CSI < u`、`CSI > 5 u`（disambiguate + report alternates）、
    /// `CSI > 4 ; 2 m`（modifyOtherKeys 2）。
    func testClaudeCodeKeyboardSetup() async {
        await rig.feed("\(Self.esc)[<u\(Self.esc)[>5u\(Self.esc)[>4;2m")
        XCTAssertEqual(rig.session.shadow.kittyKeyboardFlags, 5)
        await check(mode: "claude") { "\(Self.esc)[\($0.codepoint);5u" }
    }

    // MARK: 程序接管着鼠标、指针停在终端上

    private func flags(_ modifiers: NSEvent.ModifierFlags, keyCode: Int) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                         keyCode: UInt16(keyCode))!
    }

    /// 像真键盘那样按一次 ⌃ + 字母：⌃ 按下（flagsChanged）→ 字母按下、抬起 → ⌃ 抬起。返回这期间后端收到的字节。
    private func holdControlAndPress(_ key: Key) async -> [UInt8] {
        let before = await rig.sent(expecting: 0, timeout: 0).count
        rig.window.sendEvent(flags(.control, keyCode: kVK_Control))
        RealEvents.press(window: rig.window, characters: key.control, ignoring: String(key.letter),
                         keyCode: key.keyCode, modifiers: .control)
        rig.window.sendEvent(flags([], keyCode: kVK_Control))
        _ = await rig.sent(expecting: before + 1, timeout: 0.5)
        try? await Task.sleep(for: .milliseconds(200))
        let all = await rig.sent(expecting: 0, timeout: 0)
        return Array(all.dropFirst(before))
    }

    /// Claude Code 的全屏界面接管鼠标（`?1000h` `?1002h` `?1003h` `?1006h`），指针停在终端上不动。
    /// 只按 ⌃ 不该让程序收到鼠标移动；⌃S、⌃X 各是一串 `CSI … ;5u`，前后不夹别的。
    private func checkControlChordsWhileMouseCaptured(mouseModes: String, mode: String, onCellEdge: Bool = false,
                                                       file: StaticString = #filePath, line: UInt = #line) async {
        await rig.feed("\(Self.esc)[<u\(Self.esc)[>5u\(Self.esc)[>4;2m\(mouseModes)hello\r\n")
        guard var point = rig.windowPoint(col: 10, row: 5), let cell = rig.cellPoints else {
            return XCTFail("量不到格子尺寸", file: file, line: line)
        }
        // 停在这一格右边线里面半个点：往右 1 pt 就进了下一格。
        if onCellEdge { point.x += cell.width / 2 - 0.5 }
        let before = await rig.sent(expecting: 0, timeout: 0).count
        rig.view.mouseMoved(with: RealEvents.mouse(.mouseMoved, window: rig.window, at: point))
        // 指针真的移过来那一下照常上报（程序开了任意移动上报）。
        _ = await rig.sent(expecting: before + 1, timeout: 0.5)
        for key in Self.keys {
            let bytes = await holdControlAndPress(key)
            print("[control-key] \(mode) ⌃\(key.letter.uppercased()) → \(Self.describe(bytes))")
            XCTAssertEqual(Self.describe(bytes), Self.describe(Array("\(Self.esc)[\(key.codepoint);5u".utf8)),
                           "\(mode) ⌃\(key.letter.uppercased())：只按修饰键、鼠标没动，不该多出鼠标上报", file: file, line: line)
        }
    }

    func testControlChordsWhileProgramTracksMouseMotion() async {
        let e = Self.esc
        await checkControlChordsWhileMouseCaptured(mouseModes: "\(e)[?1000h\(e)[?1002h\(e)[?1003h\(e)[?1006h",
                                                   mode: "mouse 1003")
    }

    /// 指针正好停在两格交界上（按格上报）。
    func testControlChordsWhileProgramTracksMouseMotionOnCellEdge() async {
        let e = Self.esc
        await checkControlChordsWhileMouseCaptured(mouseModes: "\(e)[?1000h\(e)[?1002h\(e)[?1003h\(e)[?1006h",
                                                   mode: "mouse 1003 cell edge", onCellEdge: true)
    }

    func testControlChordsWhileProgramTracksMouseMotionInPixels() async {
        let e = Self.esc
        await checkControlChordsWhileMouseCaptured(mouseModes: "\(e)[?1000h\(e)[?1002h\(e)[?1003h\(e)[?1006h\(e)[?1016h",
                                                   mode: "mouse 1003+1016")
    }

    /// 只按下、松开 ⌃ / ⇧ / ⌥（不按别的键、鼠标不动）：程序一个字节都不该收到。
    func testModifierAloneReportsNothingWhileProgramTracksMouseMotion() async {
        let e = Self.esc
        await rig.feed("\(e)[<u\(e)[>5u\(e)[>4;2m\(e)[?1000h\(e)[?1002h\(e)[?1003h\(e)[?1006h\(e)[?1016hhello\r\n")
        guard let point = rig.windowPoint(col: 10, row: 5) else { return XCTFail("量不到格子尺寸") }
        rig.view.mouseMoved(with: RealEvents.mouse(.mouseMoved, window: rig.window, at: point))
        _ = await rig.sent(expecting: 1, timeout: 0.5)
        let before = await rig.sent(expecting: 0, timeout: 0).count
        for (name, modifier, keyCode) in [("⌃", NSEvent.ModifierFlags.control, kVK_Control), ("⇧", .shift, kVK_Shift),
                                          ("⌥", .option, kVK_Option)] {
            rig.window.sendEvent(flags(modifier, keyCode: keyCode))
            rig.window.sendEvent(flags([], keyCode: keyCode))
            try? await Task.sleep(for: .milliseconds(200))
            let bytes = Array(await rig.sent(expecting: 0, timeout: 0).dropFirst(before))
            XCTAssertEqual(Self.describe(bytes), Self.describe([]), "只按 \(name)")
        }
    }

    // MARK: 和真键盘一样的事件（由 CGEvent 转成，字符由系统按当前输入源算）

    /// 左 ⌃ 按着时硬件事件带的标志：`maskControl` + 设备位（左 ⌃）+ 0x100。
    private static let leftControlFlags = CGEventFlags(rawValue: 0x40101)

    private func hardwareKey(_ keyCode: Int, down: Bool, flags: CGEventFlags) -> NSEvent? {
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return nil }
        cg.flags = flags
        return NSEvent(cgEvent: cg)
    }

    private func pressHardwareControl(_ key: Key) async -> [UInt8] {
        guard let down = hardwareKey(key.keyCode, down: true, flags: Self.leftControlFlags),
              let up = hardwareKey(key.keyCode, down: false, flags: Self.leftControlFlags) else {
            XCTFail("造不出 CGEvent")
            return []
        }
        let scalars = (down.characters ?? "").unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        print("[control-key] hardware ⌃\(key.letter.uppercased()) characters=\(scalars) ignoring=\(down.charactersIgnoringModifiers ?? "nil") flags=0x\(String(down.modifierFlags.rawValue, radix: 16))")
        let before = await rig.sent(expecting: 0, timeout: 0).count
        if !rig.window.performKeyEquivalent(with: down) { rig.window.sendEvent(down) }
        rig.window.sendEvent(up)
        let all = await rig.sent(expecting: before + 1, timeout: 0.5)
        return Array(all.dropFirst(before))
    }

    func testHardwareShapedEventsInLegacyAndKittyModes() async {
        for key in Self.keys {
            let bytes = await pressHardwareControl(key)
            print("[control-key] hardware legacy ⌃\(key.letter.uppercased()) → \(Self.describe(bytes))")
            XCTAssertEqual(Self.describe(bytes), Self.describe(Array(key.control.utf8)), "legacy ⌃\(key.letter.uppercased())")
        }
        await rig.feed("\(Self.esc)[<u\(Self.esc)[>5u\(Self.esc)[>4;2m")
        for key in Self.keys {
            let bytes = await pressHardwareControl(key)
            print("[control-key] hardware claude ⌃\(key.letter.uppercased()) → \(Self.describe(bytes))")
            XCTAssertEqual(Self.describe(bytes), Self.describe(Array("\(Self.esc)[\(key.codepoint);5u".utf8)),
                           "claude ⌃\(key.letter.uppercased())")
        }
    }

    /// 只开 modifyOtherKeys 2（Claude Code 在不认 kitty 协议的终端里）。
    func testModifyOtherKeys() async {
        await rig.feed("\(Self.esc)[>4;2m")
        XCTAssertEqual(rig.session.shadow.kittyKeyboardFlags, 0)
        await check(mode: "modifyOtherKeys") { "\(Self.esc)[27;5;\($0.codepoint)~" }
    }
}
