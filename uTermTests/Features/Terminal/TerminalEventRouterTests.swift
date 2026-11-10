import XCTest
@testable import uTerm

/// 影子事件的共享分发（`TerminalEventRouter`，两端同一份）：查询的应答、远控镜像跳过什么、历史只记状态。
@MainActor
final class TerminalEventRouterTests: XCTestCase {
    private final class Outlets {
        var sent: [Data] = []
        var attention: [ProgramStatusRecord] = []
        var events: [ShadowTerminal.Event] = []
        var statusChanges = 0
    }

    private func make(mirror: Bool = false, looking: Bool = false) -> (TerminalEventRouter, ShadowTerminal, Outlets) {
        let router = TerminalEventRouter()
        let shadow = ShadowTerminal(cols: 40, rows: 10, options: TerminalScrollbackLimits(lines: 100).shadowOptions)
        let out = Outlets()
        router.isMirror = { mirror }
        router.isLooking = { looking }
        router.sendToProgram = { out.sent.append($0) }
        router.onAttention = { out.attention.append($0) }
        router.onStatusChanged = { out.statusChanges += 1 }
        router.onEvent = { out.events.append($0) }
        router.install(on: shadow)
        return (router, shadow, out)
    }

    private func feed(_ shadow: ShadowTerminal, _ text: String, history: Bool = false) {
        shadow.feed(Data(text.utf8), asHistory: history)
    }

    /// 查询的应答两端都用 uTerm 自己那条（以 ST 结尾），不管请求用的是 BEL 还是 ST；原来 iOS 发的是引擎拟的那条。
    func testQueryIsAnsweredWithTheTrackerReply() {
        let (router, shadow, out) = make()
        feed(shadow, "\u{1B}]7501;?\u{07}")
        XCTAssertEqual(out.sent, [Data(ProgramStatusTracker.queryReply)])
        withExtendedLifetime(router) {}
    }

    /// 远控镜像（主控端）：状态、查询、提示符、通知都由被控的 Mac 处理，这里一律不处理；标题、响铃照常交给平台。
    func testMirrorSkipsStatusQueryPromptAndNotification() {
        let (router, shadow, out) = make(mirror: true)
        feed(shadow, "\u{1B}]7501;state=working:app=claude-code\u{07}\u{1B}]7501;?\u{07}\u{1B}]133;A\u{07}"
             + "\u{1B}]9;hello\u{07}\u{1B}]2;title\u{07}\u{07}")
        XCTAssertFalse(router.tracker.hasRecords)
        XCTAssertTrue(out.sent.isEmpty)
        XCTAssertEqual(out.statusChanges, 0)
        XCTAssertFalse(out.events.contains { if case .notification = $0 { return true } else { return false } })
        XCTAssertTrue(out.events.contains { if case .titleChanged("title") = $0 { return true } else { return false } })
        XCTAssertTrue(out.events.contains { if case .bell = $0 { return true } else { return false } })
    }

    /// 历史字节：状态记进账（界面那份和记账副本都记），不应答、不提醒、不交给平台。
    func testHistoryOnlyRecordsStatus() {
        let (router, shadow, out) = make()
        feed(shadow, "\u{1B}]7501;state=blocked:app=claude-code\u{07}\u{1B}]7501;?\u{07}\u{1B}]9;old\u{07}"
             + "\u{1B}]2;old\u{07}\u{07}", history: true)
        XCTAssertEqual(router.tracker.display?.state, .blocked)
        XCTAssertEqual(router.journal.current.display?.state, .blocked)
        XCTAssertTrue(out.sent.isEmpty)
        XCTAssertTrue(out.attention.isEmpty)
        XCTAssertTrue(out.events.isEmpty)
    }

    /// 实时的：卡住等人要提醒；接回时认作程序的那条，程序一开口就作废。
    func testLiveReportsAlertAndEndThePresumption() {
        let (router, shadow, out) = make()
        router.presumeRunningProgram("claude")
        XCTAssertTrue(router.tracker.hasRecords)
        XCTAssertNil(router.tracker.display)
        feed(shadow, "\u{1B}]7501;state=blocked:app=claude-code\u{07}")
        XCTAssertEqual(out.attention.map(\.state), [.blocked])
        XCTAssertNil(router.tracker.presumedProgram)
        feed(shadow, "\u{1B}]133;A\u{07}")
        XCTAssertNil(router.tracker.display)
    }
}
