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
    /// `TerminalActivityCenter` 只弱引用工作区（App 里由根视图持有）：用例跑完之前得自己留着。
    private var workspace: MobileWorkspace?
    /// 交给 `TerminalActivityCenter` 的后台剩余时间。测试会话里系统不倒计时（真读只会读到「无限」），由用例来定。
    private var backgroundTime: TimeInterval = .greatestFiniteMagnitude

    override func tearDown() async throws {
        tab?.controller.close()
        tab = nil
        workspace = nil
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

    /// 实时活动现在带着的过期时间（过了这个点扩展按已暂停画）。
    private func currentStaleDate() -> Date? {
        Activity<TerminalActivityAttributes>.activities.first { $0.activityState == .active }?.content.staleDate
    }

    private func waitFor(_ timeout: Duration = .seconds(5),
                         _ predicate: @MainActor (TerminalActivityAttributes.ContentState?) -> Bool) async -> Bool {
        await MobileFakeTerminal.waitUntil(timeout: timeout) { predicate(self.currentState()) }
    }

    /// 真控制器 + 假传输的一个终端标签页，放进工作区，交给一个后台剩余时间由用例定的 `TerminalActivityCenter`。
    private func makeCenter() async throws -> (center: TerminalActivityCenter, tab: TermTab) {
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
        self.workspace = workspace
        workspace.open(.terminal(tab))
        let center = TerminalActivityCenter(backgroundTimeRemaining: { [weak self] in
            self?.backgroundTime ?? .greatestFiniteMagnitude
        })
        center.start(workspace: workspace)
        return (center, tab)
    }

    func testActivityFollowsProgramStatusAndPausesInBackground() async throws {
        let (center, tab) = try await makeCenter()
        _ = center   // 用例跑完之前别放掉

        osc("state=working:app=claude-code")
        let appeared = await waitFor { $0?.rows.first?.tone == .working }
        XCTAssertTrue(appeared, "程序报了运行中：实时活动出现")
        XCTAssertEqual(currentState()?.rows.first?.id, tab.id)
        XCTAssertEqual(currentState()?.rows.first?.program, "Claude Code")
        XCTAssertEqual(Activity<TerminalActivityAttributes>.activities.filter { $0.activityState == .active }.count, 1)

        osc("state=blocked:app=claude-code:kind=permission")
        let blocked = await waitFor { $0?.rows.first?.tone == .attention }
        XCTAssertTrue(blocked, "卡住等确认：跟着变")

        // 进后台（在前台发通知模拟）。刚切出去系统还没开始倒计时，读到的是「无限」：不急着暂停，内容照常实时。
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(currentState()?.paused, false, "后台时间读到「无限」：照常实时，不定格")
        XCTAssertEqual(currentState()?.rows.first?.tone, .attention)

        // 系统开始倒计时，剩下的时间只比提前量多一点：下一次再看（隔 `unboundedRecheck`）时发现，随即定格。
        backgroundTime = TerminalActivityCenter.pauseLead + 0.5
        let paused = await waitFor(.seconds(TerminalActivityCenter.unboundedRecheck + 10)) { $0?.paused == true }
        XCTAssertTrue(paused, "快被挂起了：定格为已暂停")
        XCTAssertEqual(currentState()?.footer, TerminalActivityContent.pausedText)
        XCTAssertNil(currentStaleDate(), "已暂停的内容不带过期时间（已经按暂停画了）")

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        let resumed = await waitFor { $0?.paused == false && $0?.rows.first?.tone == .attention }
        XCTAssertTrue(resumed, "回到前台：恢复实时")

        osc("state=idle:app=claude-code")
        let ended = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            Activity<TerminalActivityAttributes>.activities.allSatisfy { $0.activityState != .active }
        }
        XCTAssertTrue(ended, "程序都停了：收掉")
    }

    /// 没有推送，App 被挂起后没人再更新：进后台时内容没变也要把过期时间带上（过期了扩展按已暂停画），
    /// 后台时间读到「无限」时每次复查往后挪，回到前台清掉。
    func testStaleDateIsPushedInBackgroundAndClearedInForeground() async throws {
        let (center, _) = try await makeCenter()
        _ = center

        osc("state=working:app=claude-code")
        let appeared = await waitFor { $0?.rows.first?.tone == .working }
        XCTAssertTrue(appeared)
        XCTAssertNil(currentStaleDate(), "在前台不会过期")

        // 进后台，内容和上一次推的一样；后台时间读到「无限」。
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let stamped = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) { self.currentStaleDate() != nil }
        XCTAssertTrue(stamped, "进后台：内容没变也带上过期时间")
        let first = try XCTUnwrap(currentStaleDate())
        XCTAssertGreaterThan(first, Date(), "过期时间在将来")
        XCTAssertLessThanOrEqual(first, Date().addingTimeInterval(TerminalActivityCenter.unboundedRecheck * 2),
                                 "「无限」时只往后给一小段")
        XCTAssertEqual(currentState()?.paused, false)

        // 隔一次复查：往后挪了，没有停在第一次给的那个点上。
        let recheck = TerminalActivityCenter.unboundedRecheck
        let moved = await MobileFakeTerminal.waitUntil(timeout: .seconds(recheck + 5)) {
            (self.currentStaleDate() ?? first) >= first.addingTimeInterval(recheck - 1)
        }
        XCTAssertTrue(moved, "后台时间一直是「无限」：每次复查把过期时间往后挪")
        XCTAssertGreaterThan(try XCTUnwrap(currentStaleDate()), Date())
        XCTAssertEqual(currentState()?.paused, false, "没到暂停的时候：内容照常实时")

        // 回到前台，内容还是没变：过期时间清掉。
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        let cleared = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            self.currentState() != nil && self.currentStaleDate() == nil
        }
        XCTAssertTrue(cleared, "回到前台：不再过期")
        XCTAssertEqual(currentState()?.paused, false)
        XCTAssertEqual(currentState()?.rows.first?.tone, .working)
    }

    /// 内容没变时，过期时间差多少才值得再推一次。
    func testStaleDateChangeNeedsSlack() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let slack = TerminalActivityCenter.staleDateSlack
        XCTAssertFalse(TerminalActivityCenter.staleDateChanged(from: nil, to: nil), "前台、已暂停：一直没有")
        XCTAssertTrue(TerminalActivityCenter.staleDateChanged(from: nil, to: base), "进后台：从无到有")
        XCTAssertTrue(TerminalActivityCenter.staleDateChanged(from: base, to: nil), "回前台：从有到无")
        XCTAssertFalse(TerminalActivityCenter.staleDateChanged(from: base, to: base.addingTimeInterval(0.02)),
                       "系统在倒计时：「现在 + 剩余」每次只差几毫秒，不重推")
        XCTAssertFalse(TerminalActivityCenter.staleDateChanged(from: base, to: base.addingTimeInterval(-slack / 2)))
        XCTAssertTrue(TerminalActivityCenter.staleDateChanged(from: base, to: base.addingTimeInterval(slack)))
        XCTAssertTrue(TerminalActivityCenter.staleDateChanged(from: base, to: base.addingTimeInterval(-slack)),
                      "往前挪（后台保持结束）也算")
        XCTAssertLessThan(slack, TerminalActivityCenter.unboundedRecheck, "「无限」时每次复查都得挪得动")
    }
}
