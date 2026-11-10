import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 程序写剪贴板（OSC 52）以影子终端为准，同 Mac 的 `TerminalOSCRegressionTests`：标签藏着、surface 没建或放掉了也写；
/// surface 那边配置成 deny（不写两遍、回放进 surface 时不把历史里的再写一遍）；读剪贴板一律不答。
///
/// 写进终端的 `pasteboard`，用例换成私有的那块：模拟器的系统剪贴板默认和 Mac 同步，别去动它。只读它的 `changeCount`
/// 核 surface 没写（读计数不会弹粘贴提示，也不改内容）。
@MainActor
final class TerminalOSC52Tests: XCTestCase {
    private var pasteboard: UIPasteboard!

    override func setUp() async throws {
        pasteboard = UIPasteboard.withUniqueName()
    }

    override func tearDown() async throws {
        if let pasteboard { UIPasteboard.remove(withName: pasteboard.name) }
    }

    private func makeHost() async throws -> GhosttyProbeHost {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 500))
        host.bridge.pasteboard = pasteboard
        try await host.waitUntilReady()
        host.bridge.inputLog = []
        return host
    }

    private static func osc52(_ text: String) -> String {
        "\u{1B}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}"
    }

    /// 等 surface 把喂进去的字节解析完，再给它的回调（写剪贴板、应答）一点时间。
    private func settle(_ host: GhosttyProbeHost) async throws {
        host.bridge.outputPump.waitForCatchUp()
        host.bridge.session.waitForPendingOutput()
        try await Task.sleep(for: .milliseconds(150))
    }

    func testOSC52WritesToTheTerminalsPasteboardAndNotThroughTheSurface() async throws {
        let host = try await makeHost()
        defer { host.close() }
        let general = UIPasteboard.general.changeCount
        host.feedAndWait(Self.osc52("hello 世界"))
        XCTAssertEqual(pasteboard.string, "hello 世界")
        try await settle(host)
        XCTAssertEqual(UIPasteboard.general.changeCount, general, "surface 配置成 deny，不该再写一遍系统剪贴板")
    }

    func testOSC52WithInvalidBase64LeavesPasteboardAlone() async throws {
        let host = try await makeHost()
        defer { host.close() }
        pasteboard.string = "原来的"
        host.feedAndWait("\u{1B}]52;c;@@@not-base64@@@\u{07}")
        XCTAssertEqual(pasteboard.string, "原来的")
    }

    /// 画面不吃字节的时候（App 在后台、标签藏着）照样写：影子一直在吃。
    func testOSC52WritesWhileOnlyTheShadowIsFed() async throws {
        let host = try await makeHost()
        defer { host.close() }
        host.bridge.setAppInBackground(true)
        XCTAssertFalse(host.bridge.outputPump.isFeedingSurface)
        host.bridge.feed(Data(Self.osc52("from background").utf8))
        XCTAssertEqual(pasteboard.string, "from background")
        host.bridge.setAppInBackground(false)
    }

    /// 回放不写：远控快照还原进影子（不解析字节）、影子回放进 surface（surface 是 deny）、影子关着事件时喂的历史，
    /// 历史里的 OSC 52 都不再写一遍。
    func testReplaysDoNotWriteThePasteboardAgain() async throws {
        let host = try await makeHost()
        defer { host.close() }
        let source = ShadowTerminal(cols: 60, rows: 20, options: GhosttyTerminalBridge.scrollback.shadowOptions)
        source.feed(Data(("history\r\n" + Self.osc52("old") + "$ ").utf8))
        let snapshot = try source.snapshot()
        pasteboard.string = "原来的"
        let general = UIPasteboard.general.changeCount

        host.bridge.outputPump.applySnapshot(snapshot)
        try await settle(host)
        XCTAssertTrue(host.bridge.shadow.viewportText().contains("history"), "快照应当进了影子")
        XCTAssertEqual(pasteboard.string, "原来的", "快照还原不写剪贴板")

        // 进出一次后台：回前台时影子回放进 surface。
        host.bridge.setAppInBackground(true)
        host.bridge.setAppInBackground(false)
        try await settle(host)
        XCTAssertGreaterThan(host.bridge.outputPump.currentStats.replays, 0, "用例前提：回放过")
        XCTAssertEqual(pasteboard.string, "原来的", "回放进 surface 不写剪贴板")
        XCTAssertEqual(UIPasteboard.general.changeCount, general)

        host.bridge.shadow.setEventsSuppressed(true)
        host.feedAndWait(Self.osc52("suppressed"))
        host.bridge.shadow.setEventsSuppressed(false)
        XCTAssertEqual(pasteboard.string, "原来的", "影子关着事件（回放历史）时不写")
    }

    /// 远端程序不能靠 OSC 52 读走手机的剪贴板：surface 在吃字节（它来答）、只喂影子（影子来答）两种情况都不答。
    func testOSC52QueryIsNeverAnswered() async throws {
        let host = try await makeHost()
        defer { host.close() }
        pasteboard.string = "秘密"
        host.feedAndWait("\u{1B}]52;c;?\u{07}")
        try await settle(host)
        XCTAssertEqual(host.bridge.inputLog ?? [], [], "surface 不该答")

        host.bridge.setAppInBackground(true)
        host.bridge.feed(Data("\u{1B}]52;c;?\u{07}".utf8))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.bridge.inputLog ?? [], [], "影子不该答")
        host.bridge.setAppInBackground(false)
    }
}
