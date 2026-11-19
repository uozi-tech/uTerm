import ActivityKit
import SwiftData
import UIKit
import XCTest
@testable import uTermMobile

/// 终端状态的实时活动接真控制器 + 假传输：程序报状态 → 实时活动出现、跟着变；进后台 → 定格为已暂停；
/// 程序都停了 → 收掉。在真机上跑才会真的出现在灵动岛 / 锁屏上（模拟器也能建，只是看不到灵动岛）。
@MainActor
final class TerminalActivityCenterTests: XCTestCase {
    private var tab: TermTab?

    override func tearDown() async throws {
        tab?.controller.close()
        for activity in Activity<TerminalActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        try await super.tearDown()
    }

    private func osc(_ payload: String) {
        tab?.controller.terminal.feed(Data("\u{1b}]7501;\(payload)\u{1b}\\".utf8))
    }

    private func currentState() -> TerminalActivityAttributes.ContentState? {
        Activity<TerminalActivityAttributes>.activities.first { $0.activityState == .active }?.content.state
    }

    private func waitFor(_ timeout: Duration = .seconds(5),
                         _ predicate: @MainActor (TerminalActivityAttributes.ContentState?) -> Bool) async -> Bool {
        await MobileFakeTerminal.waitUntil(timeout: timeout) { predicate(self.currentState()) }
    }

    func testActivityFollowsProgramStatusAndPausesInBackground() async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw XCTSkip("这台设备关了实时活动（设置 › uTerm › 实时活动）")
        }
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (tab, _) = MobileFakeTerminal.tab(host: host, MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0,
                                                                                 corpus: .plain, echoesInput: false))
        self.tab = tab
        tab.controller.isForeground = false   // 没人看着：结果留在标签上
        tab.controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)

        let workspace = MobileWorkspace()
        workspace.open(.terminal(tab))
        let center = TerminalActivityCenter()
        center.start(workspace: workspace)

        osc("state=working:app=claude-code")
        let appeared = await waitFor { $0?.rows.first?.tone == .working }
        XCTAssertTrue(appeared, "程序报了运行中：实时活动出现")
        XCTAssertEqual(currentState()?.rows.first?.id, tab.id)
        XCTAssertEqual(currentState()?.rows.first?.program, "Claude Code")
        XCTAssertEqual(Activity<TerminalActivityAttributes>.activities.filter { $0.activityState == .active }.count, 1)

        osc("state=blocked:app=claude-code:kind=permission")
        let blocked = await waitFor { $0?.rows.first?.tone == .attention }
        XCTAssertTrue(blocked, "卡住等确认：跟着变")

        // 进后台：先实时，系统给的时间快用完时定格。这里在前台发通知模拟，系统给的时间是「无限」，按马上要挂起处理。
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let paused = await waitFor { $0?.paused == true }
        XCTAssertTrue(paused, "快被挂起了：定格为已暂停")
        XCTAssertEqual(currentState()?.footer, TerminalActivityContent.pausedText)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        let resumed = await waitFor { $0?.paused == false && $0?.rows.first?.tone == .attention }
        XCTAssertTrue(resumed, "回到前台：恢复实时")

        osc("state=idle:app=claude-code")
        let ended = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            Activity<TerminalActivityAttributes>.activities.allSatisfy { $0.activityState != .active }
        }
        XCTAssertTrue(ended, "程序都停了：收掉")
    }
}
