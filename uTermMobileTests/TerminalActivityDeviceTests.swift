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

    /// 看排版用：不接终端，直接按几组写好的内容建实时活动，外面截灵动岛 / 锁屏。模拟器上也能跑。
    /// `TEST_RUNNER_UTERM_LIVE_ACTIVITY_SHOWCASE=1` 打开。
    /// `simctl io screenshot` 截不到灵动岛，也锁不了屏（单元测试里按不了锁屏键）：在 DeviceHub 里看。每组停 `…_SHOWCASE_SECONDS`（默认 40）秒，切换时打印 `[la-scene] <名字>`。
    func testLiveActivityLayoutShowcase() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["UTERM_LIVE_ACTIVITY_SHOWCASE"] != nil else { throw XCTSkip("手动看排版用，见注释") }
        let hold = Double(env["UTERM_LIVE_ACTIVITY_SHOWCASE_SECONDS"] ?? "") ?? 40
        for activity in Activity<TerminalActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let now = Date()
        func entry(_ title: String, _ host: String, _ state: ProgramState,
                   kind: ProgramBlockKind? = nil) -> TerminalActivityEntry {
            TerminalActivityEntry(tabID: UUID(), title: title, host: host,
                                  status: ProgramStatusRecord(state: state, kind: kind, progress: nil,
                                                              app: "claude-code", title: nil, message: nil))
        }
        let mac = "Jacky 的 MacBook Pro"
        let same = [entry("ios-app-store-subscription", mac, .working),
                    entry("Worktree 与已合并分支清理", mac, .working),
                    entry("官网与 GitHub README 多语言", mac, .working)]
        let mixed = [entry("ios-app-store-subscription", mac, .blocked, kind: .permission),
                     entry("Worktree 与已合并分支清理", mac, .working),
                     entry("deploy", "prod-1", .error),
                     entry("官网与 GitHub README 多语言", mac, .done)]
        let scenes: [(String, [TerminalActivityEntry], TerminalActivityPhase)] = [
            ("same", same, .live),
            ("mixed", mixed, .live),
            ("single", [entry("ios-app-store-subscription", mac, .blocked, kind: .permission)], .live),
            ("keeping", same, .keeping(until: now.addingTimeInterval(900))),
        ]
        let since = Dictionary(uniqueKeysWithValues: (same + mixed).enumerated().map {
            ($0.element.tabID, now.addingTimeInterval(-Double(20 + 45 * $0.offset)))
        })

        var activity: Activity<TerminalActivityAttributes>?
        for (name, entries, phase) in scenes {
            let state = try XCTUnwrap(TerminalActivityContent.make(entries: entries, since: since, phase: phase))
            let content = ActivityContent(state: state, staleDate: nil)
            if let activity {
                await activity.update(content)
            } else {
                activity = try Activity.request(attributes: TerminalActivityAttributes(), content: content)
            }
            print("[la-scene] \(name)")
            try await Task.sleep(for: .seconds(hold))
        }
        await activity?.end(nil, dismissalPolicy: .immediate)
    }
}
