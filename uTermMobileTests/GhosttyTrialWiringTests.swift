#if DEBUG
import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// M16「Ghostty 试用」入口的接线（不点界面）：开关打开后新建的控制器走 GhosttyKit，
/// 后端输出进 Ghostty、软键盘输入与键盘条按键回到后端、粘滞 Ctrl 状态同步到控制器。
@MainActor
final class GhosttyTrialWiringTests: XCTestCase {
    func testTrialControllerRoutesThroughGhostty() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DefaultsKey.debugGhosttyTrial)
        defaults.set(true, forKey: DefaultsKey.debugGhosttyTrial)
        // 测试宿主与装机版共用偏好：用完原样放回，别把用户的开关改掉。
        defer {
            if let previous { defaults.set(previous, forKey: DefaultsKey.debugGhosttyTrial) }
            else { defaults.removeObject(forKey: DefaultsKey.debugGhosttyTrial) }
        }

        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        let bridge = try XCTUnwrap(controller.ghostty, "开关打开后新控制器应当带 Ghostty bridge")
        XCTAssertNil(controller.terminalView)

        let window = try makeSpikeWindow(size: CGSize(width: 393, height: 600))
        defer { bridge.view.removeFromSuperview(); window.isHidden = true }
        bridge.view.frame = window.bounds
        window.addSubview(bridge.view)
        window.makeKey()
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.view.surface != nil && bridge.grid != nil }
        XCTAssertTrue(ready, "Ghostty surface 没建起来")

        controller.ownsKeyboard = true
        controller.focusKeyboard()
        XCTAssertTrue(bridge.view.isFirstResponder, "控制器聚焦应当落到 Ghostty 视图")
        XCTAssertTrue(controller.keyboardShown, "Ghostty 视图的焦点变化要同步回控制器")

        // 软键盘落字 → 后端（假后端原样回显）→ Ghostty 屏上。
        bridge.view.insertText("e")
        bridge.view.insertText("c")
        let echoed = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            bridge.session.readViewportText()?.contains("ec") == true
        }
        XCTAssertTrue(echoed, "回显没上 Ghostty 屏：\(String((bridge.session.readViewportText() ?? "").prefix(80)))")

        // 键盘条：Esc 走终端按键编码。
        let before = await handles.latest?.writtenBytes ?? 0
        controller.sendKey(TerminalKeyCatalog.escape)
        try await Task.sleep(for: .milliseconds(200))
        let after = await handles.latest?.writtenBytes ?? 0
        XCTAssertEqual(after - before, 1, "键盘条 Esc 应当发 1 个字节")

        // 粘滞 Ctrl：上膛后控制器亮起，下一个字符用掉后复位。
        controller.toggleControl()
        XCTAssertTrue(controller.controlArmed)
        bridge.view.insertText("c")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(controller.controlArmed, "Ctrl 用掉后应当复位")
        let writes = await handles.latest?.writes ?? []
        XCTAssertEqual(writes.last.map { [UInt8]($0) }, [0x03], "Ctrl+c 应当发 0x03")

        controller.close()
    }
}
#endif
