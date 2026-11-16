import XCTest
@testable import uTermMobile

/// 键盘条 AI 面板的短语：存取、增删排序的规则（`TerminalPhrases`）。
final class TerminalPhrasesTests: XCTestCase {
    func testDefaultsIncludeClaudeAndCodexLaunchers() {
        let launch = TerminalPhrases.defaults.launch
        XCTAssertEqual(launch.first, "claude")
        XCTAssertTrue(launch.contains("codex"))
        XCTAssertFalse(launch.contains { $0.contains("dangerously") || $0.contains("--yolo") },
                       "默认启动命令不能带放开权限的参数")
    }

    func testUnchangedPhrasesStoreAsEmptyString() {
        XCTAssertEqual(TerminalPhrases.defaults.encoded, "", "没改过就存空串，以后默认值改了跟着变")
        XCTAssertEqual(TerminalPhrases.decode(""), .defaults)
    }

    func testRoundTripsEdits() {
        var phrases = TerminalPhrases.defaults
        XCTAssertEqual(phrases.add("claude --model opus", to: .launch), .added)
        phrases.reset(.slash)
        phrases.prompts = ["继续"]
        XCTAssertEqual(TerminalPhrases.decode(phrases.encoded), phrases)
    }

    func testGarbageAndMissingGroupsFallBackToDefaults() {
        XCTAssertEqual(TerminalPhrases.decode("not json"), .defaults)
        let decoded = TerminalPhrases.decode(#"{"launch":["codex"]}"#)
        XCTAssertEqual(decoded.launch, ["codex"])
        XCTAssertEqual(decoded.prompts, TerminalPhrases.defaultPrompts, "缺的组用默认值")
        XCTAssertEqual(decoded.slash, TerminalPhrases.defaultSlash)
    }

    func testDecodeDropsDuplicatesBlanksAndMultiline() {
        let decoded = TerminalPhrases.decode(#"{"launch":["claude"," claude ","","a\nb","codex"],"prompts":[],"slash":[]}"#)
        XCTAssertEqual(decoded.launch, ["claude", "codex"], "面板按文本区分键帽，不能有重复")
        XCTAssertEqual(decoded.prompts, [], "用户清空的组保持为空")
    }

    func testAddRejectsBadInput() {
        var phrases = TerminalPhrases(launch: ["claude"], prompts: [], slash: [])
        XCTAssertEqual(phrases.add("   ", to: .launch), .empty)
        XCTAssertEqual(phrases.add(" claude ", to: .launch), .duplicate)
        XCTAssertEqual(phrases.add("a\nb", to: .launch), .multiline)
        XCTAssertEqual(phrases.add(String(repeating: "x", count: TerminalPhrases.maxLength + 1), to: .launch), .tooLong)
        XCTAssertEqual(phrases.add("  codex  ", to: .launch), .added)
        XCTAssertEqual(phrases.launch, ["claude", "codex"], "首尾空白去掉再存")

        for index in 0..<TerminalPhrases.maxPerKind { phrases.add("p\(index)", to: .prompt) }
        XCTAssertEqual(phrases.add("one more", to: .prompt), .full)
    }

    /// 参数语义同 SwiftUI 的 `onMove`：`destination` 是移动前数组里的插入位置。
    func testMoveMatchesOnMoveSemantics() {
        var phrases = TerminalPhrases(launch: ["a", "b", "c", "d"], prompts: [], slash: [])
        phrases.move(fromOffsets: [0], toOffset: 3, in: .launch)
        XCTAssertEqual(phrases.launch, ["b", "c", "a", "d"])
        phrases.move(fromOffsets: [3], toOffset: 0, in: .launch)
        XCTAssertEqual(phrases.launch, ["d", "b", "c", "a"])
        phrases.move(fromOffsets: [0, 2], toOffset: 4, in: .launch)
        XCTAssertEqual(phrases.launch, ["b", "a", "d", "c"])
    }

    func testRemoveAndReset() {
        var phrases = TerminalPhrases.defaults
        phrases.remove(atOffsets: [0, 1], from: .launch)
        XCTAssertEqual(phrases.launch, Array(TerminalPhrases.defaultLaunch.dropFirst(2)))
        phrases.reset(.launch)
        XCTAssertEqual(phrases, .defaults)
    }
}
