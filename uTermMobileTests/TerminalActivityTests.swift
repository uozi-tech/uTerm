import BackgroundTasks
import Foundation
import XCTest
@testable import uTermMobile

/// 终端状态的实时活动（灵动岛 / 锁屏）与「离开后继续运行」：内容怎么算、什么时候提醒、什么时候提前结束、链接怎么解析。
/// 实时活动真的出现在灵动岛上、后台保持真的续命，要在真机上看（见 docs/live-activity.md）。
final class TerminalActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ id: UUID = UUID(), title: String = "api", host: String = "prod-1",
                       state: ProgramState, kind: ProgramBlockKind? = nil, app: String? = "claude-code",
                       message: String? = nil) -> TerminalActivityEntry {
        TerminalActivityEntry(tabID: id, title: title, host: host,
                              status: ProgramStatusRecord(state: state, kind: kind, progress: nil, app: app,
                                                          title: nil, message: message))
    }

    // MARK: 内容

    func testNothingWorthWatchingMeansNoActivity() {
        XCTAssertNil(TerminalActivityContent.make(entries: [], since: [:], phase: .live, now: t0))
        // `idle` 不上（标签页上也不显示）。
        XCTAssertNil(TerminalActivityContent.make(entries: [entry(state: .idle)], since: [:], phase: .live, now: t0))
    }

    func testRowsRankedByWhatNeedsTheUserFirst() throws {
        let working = entry(title: "w", state: .working)
        let done = entry(title: "d", state: .done)
        let blocked = entry(title: "b", state: .blocked, kind: .permission)
        let failed = entry(title: "f", state: .error)
        let state = try XCTUnwrap(TerminalActivityContent.make(
            entries: [working, done, blocked, failed], since: [:], phase: .live, now: t0))
        XCTAssertEqual(state.rows.map(\.title), ["b", "f", "w"], "等人 > 出错 > 运行中 > 完成，最多 3 行")
        XCTAssertEqual(state.overflow, 1)
        XCTAssertNotNil(state.overflowText)
        XCTAssertEqual(state.rows[0].tone, .attention)
        XCTAssertEqual(state.rows[0].program, "Claude Code")
        XCTAssertEqual(state.rows[0].shortStatus, TerminalActivityContent.shortStatus(of: blocked.status))
    }

    func testSameRankMostRecentChangeFirstThenTabOrder() throws {
        let a = entry(title: "a", state: .working)
        let b = entry(title: "b", state: .working)
        let c = entry(title: "c", state: .working)
        let since = [a.tabID: t0, b.tabID: t0.addingTimeInterval(5), c.tabID: t0]
        let state = try XCTUnwrap(TerminalActivityContent.make(entries: [a, b, c], since: since, phase: .live, now: t0))
        XCTAssertEqual(state.rows.map(\.title), ["b", "a", "c"])
    }

    func testHostOmittedWhenSameAsTitle() throws {
        let state = try XCTUnwrap(TerminalActivityContent.make(
            entries: [entry(title: "prod-1", host: "prod-1", state: .working)], since: [:], phase: .live, now: t0))
        XCTAssertNil(state.rows[0].host)
    }

    func testPhasesSetFooterAndCountdown() throws {
        let entries = [entry(state: .working)]
        let live = try XCTUnwrap(TerminalActivityContent.make(entries: entries, since: [:], phase: .live, now: t0))
        XCTAssertNil(live.footer)
        XCTAssertNil(live.keepUntil)
        XCTAssertFalse(live.paused)

        let until = t0.addingTimeInterval(1800)
        let keeping = try XCTUnwrap(TerminalActivityContent.make(entries: entries, since: [:],
                                                                   phase: .keeping(until: until), now: t0))
        XCTAssertEqual(keeping.keepUntil, until)
        XCTAssertNotNil(keeping.footer)

        let paused = TerminalActivityContent.paused(keeping)
        XCTAssertTrue(paused.paused)
        XCTAssertNil(paused.keepUntil, "暂停了就不再倒计时")
        XCTAssertEqual(paused.footer, paused.pausedText)
        XCTAssertEqual(paused.rows, keeping.rows, "暂停只换底行，行保持最后的样子")
    }

    func testContentFitsActivityKitBudget() throws {
        // ActivityKit 的内容上限是 4 KB。标题、消息都取规格允许的最长，3 行加溢出也要放得下。
        let long = String(repeating: "长", count: 192)
        let entries = (0..<8).map { _ in
            entry(title: long, host: long, state: .blocked, kind: .question, app: String(repeating: "x", count: 32))
        }
        let state = try XCTUnwrap(TerminalActivityContent.make(entries: entries, since: [:], phase: .keeping(until: t0), now: t0))
        let bytes = try JSONEncoder().encode(state).count
        XCTAssertLessThan(bytes, 4096, "\(bytes) 字节")
    }

    // MARK: 计时起点

    func testSinceRestartsOnlyWhenStateOrReasonChanges() {
        let id = UUID()
        var book = TerminalActivitySinceBook()
        book.update([entry(id, state: .working)], now: t0)
        book.update([entry(id, state: .working)], now: t0.addingTimeInterval(10))
        XCTAssertEqual(book.since[id], t0, "还在运行中：不重新计时")
        book.update([entry(id, state: .blocked, kind: .permission)], now: t0.addingTimeInterval(20))
        XCTAssertEqual(book.since[id], t0.addingTimeInterval(20))
        book.update([entry(id, state: .blocked, kind: .question)], now: t0.addingTimeInterval(30))
        XCTAssertEqual(book.since[id], t0.addingTimeInterval(30), "卡住的原因变了也算新状态")
        book.update([], now: t0.addingTimeInterval(40))
        XCTAssertNil(book.since[id], "没状态了就忘掉")
    }

    // MARK: 提醒

    func testNotifiesOnlyOnTransitionIntoNoteworthyStateInBackground() {
        let id = UUID()
        var transitions = TerminalActivityTransitions()
        // 前台看到的：只记不提醒。
        XCTAssertTrue(transitions.update([entry(id, state: .blocked)], notify: false, now: t0).isEmpty)
        // 进后台，状态没变：不补发。
        XCTAssertTrue(transitions.update([entry(id, state: .blocked)], notify: true, now: t0.addingTimeInterval(5)).isEmpty)
        XCTAssertTrue(transitions.update([entry(id, state: .working)], notify: true, now: t0.addingTimeInterval(10)).isEmpty,
                      "运行中不提醒")
        XCTAssertEqual(transitions.update([entry(id, state: .done)], notify: true, now: t0.addingTimeInterval(20)).count, 1)
        XCTAssertTrue(transitions.update([entry(id, state: .done)], notify: true, now: t0.addingTimeInterval(30)).isEmpty,
                      "同一个状态只提醒一次")
    }

    func testRateLimitsFlappingTab() {
        let id = UUID()
        var transitions = TerminalActivityTransitions()
        XCTAssertEqual(transitions.update([entry(id, state: .blocked)], notify: true, now: t0).count, 1)
        XCTAssertTrue(transitions.update([entry(id, state: .error)], notify: true, now: t0.addingTimeInterval(1)).isEmpty,
                      "两秒内又变：不刷屏")
        XCTAssertEqual(transitions.update([entry(id, state: .done)], notify: true, now: t0.addingTimeInterval(3)).count, 1)
    }

    // MARK: 后台保持提前结束

    func testKeepAliveEndsAfterProgramsStopForGrace() {
        var auto = TerminalKeepAliveAutoEnd()
        XCTAssertFalse(auto.shouldEnd(busy: false, now: t0, grace: 60), "一直没有程序在跑：保持到时间")
        XCTAssertFalse(auto.shouldEnd(busy: false, now: t0.addingTimeInterval(600), grace: 60))
        XCTAssertFalse(auto.shouldEnd(busy: true, now: t0.addingTimeInterval(601), grace: 60))
        XCTAssertFalse(auto.shouldEnd(busy: false, now: t0.addingTimeInterval(610), grace: 60))
        XCTAssertFalse(auto.shouldEnd(busy: false, now: t0.addingTimeInterval(660), grace: 60))
        XCTAssertFalse(auto.shouldEnd(busy: true, now: t0.addingTimeInterval(665), grace: 60), "又跑起来了：重新等")
        XCTAssertFalse(auto.shouldEnd(busy: false, now: t0.addingTimeInterval(670), grace: 60))
        XCTAssertTrue(auto.shouldEnd(busy: false, now: t0.addingTimeInterval(730), grace: 60))
    }

    // MARK: 链接

    func testLinkRoundTrip() {
        let id = UUID()
        let url = TerminalActivityAttributes.link(tab: id)
        XCTAssertEqual(url.absoluteString, "uterm://terminal/\(id.uuidString)")
        XCTAssertEqual(TerminalActivityAttributes.tabID(from: url), .some(id))
        XCTAssertEqual(TerminalActivityAttributes.tabID(from: TerminalActivityAttributes.link(tab: nil)), .some(nil))
        XCTAssertNil(TerminalActivityAttributes.tabID(from: URL(string: "uterm://relay?x=1")!), "别的 uterm 链接不归它")
        XCTAssertEqual(TerminalActivityAttributes.tabID(from: URL(string: "uterm://terminal/garbage")!), .some(nil))
    }

    // MARK: Info.plist

    func testLiveActivitiesDeclared() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool, true)
    }

    @MainActor
    func testKeepAliveIdentifierIsPermitted() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("BGContinuedProcessingTask 需要 iOS 26") }
        let identifier = TerminalKeepAlive.identifierPrefix + "test." + UUID().uuidString
        // 系统在自己的队列上调启动回调（真机上提交后会马上启动）：闭包不能带主线程隔离，否则一进来就崩。
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil,
            launchHandler: ContinuedProcessingHandlers.launchHandler { (task: BGTask) in task.setTaskCompleted(success: true) })
        XCTAssertTrue(registered, "Info.plist 的 BGTaskSchedulerPermittedIdentifiers 没登记 com.uozi.uTerm.terminal.*")
    }

    func testWidgetExtensionEmbedded() throws {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let appex = plugIns.appendingPathComponent("uTermLiveActivity.appex")
        let info = try XCTUnwrap(Bundle(url: appex)?.infoDictionary)
        let ext = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.widgetkit-extension")
        XCTAssertEqual(info["CFBundleVersion"] as? String, Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                       "扩展的 build 号要和 App 一致，否则上传会被拒")
    }
}
