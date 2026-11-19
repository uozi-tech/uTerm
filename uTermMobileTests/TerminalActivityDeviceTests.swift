import ActivityKit
import SwiftData
import UIKit
import XCTest
@testable import uTermMobile

/// 真机上看实时活动：建好之后在测试里按时间表改状态，外面的脚本切后台、截屏（灵动岛 / 锁屏）。
/// 默认跳过；`TEST_RUNNER_UTERM_LIVE_ACTIVITY_DEVICE=plain|keep` 打开（keep = 同时开「离开后继续运行」）。
///
/// 时间表（从打印 `[la-ready]` 起算）：0 s 运行中 → 15 s 等待确认 → 25 s 完成 → 一直记录到 75 s。
/// 每 5 秒打印一行 `[la-state]`：实时活动的内容、App 状态、系统给的后台时间。
@MainActor
final class TerminalActivityDeviceTests: XCTestCase {
    func testLiveActivityOnDevice() async throws {
        let mode = ProcessInfo.processInfo.environment["UTERM_LIVE_ACTIVITY_DEVICE"] ?? ""
        guard mode == "plain" || mode == "keep" else { throw XCTSkip("真机手动验证用，见类注释") }

        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (tab, _) = MobileFakeTerminal.tab(host: host, MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0,
                                                                                 corpus: .plain, echoesInput: false))
        defer { tab.controller.close() }
        tab.controller.isForeground = false
        tab.controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)
        let workspace = MobileWorkspace()
        workspace.open(.terminal(tab))
        let center = TerminalActivityCenter()
        center.start(workspace: workspace)

        func osc(_ payload: String) {
            tab.controller.terminal.feed(Data("\u{1b}]7501;\(payload)\u{1b}\\".utf8))
        }
        osc("state=working:app=claude-code")
        let appeared = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            !Activity<TerminalActivityAttributes>.activities.isEmpty
        }
        XCTAssertTrue(appeared)

        if mode == "keep" {
            XCTAssertTrue(center.keepAlive.start(minutes: 15), "系统不让提交后台继续处理")
            let running = await MobileFakeTerminal.waitUntil(timeout: .seconds(10)) { center.keepAlive.isRunningInSystem }
            print("[la-keep] submitted=\(center.keepAlive.isActive) running=\(running)")
        }
        print("[la-ready]")

        let start = Date()
        var step = 0
        while Date().timeIntervalSince(start) < 75 {
            let t = Date().timeIntervalSince(start)
            if step == 0, t >= 15 { osc("state=blocked:app=claude-code:kind=permission"); step = 1 }
            if step == 1, t >= 25 { osc("state=done:app=claude-code"); step = 2 }
            let activity = Activity<TerminalActivityAttributes>.activities.first
            let state = activity?.content.state
            let app = UIApplication.shared.applicationState == .background ? "background"
                : UIApplication.shared.applicationState == .active ? "active" : "inactive"
            let remaining = UIApplication.shared.backgroundTimeRemaining
            let remainingText = remaining > 1e6 ? "unbounded" : "\(Int(remaining))"
            print("[la-state] t=\(Int(t)) app=\(app) remaining=\(remainingText) "
                  + "activity=\(activity.map { "\($0.activityState)" } ?? "nil") "
                  + "paused=\(state.map { "\($0.paused)" } ?? "-") tone=\(state?.rows.first?.tone.rawValue ?? "-") "
                  + "keep=\(center.keepAlive.isActive) systemKeep=\(center.keepAlive.isRunningInSystem)")
            try await Task.sleep(for: .seconds(5))
        }
        center.keepAlive.stop()
    }
}
