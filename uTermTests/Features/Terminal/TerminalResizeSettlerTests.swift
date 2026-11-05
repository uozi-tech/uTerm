import XCTest
@testable import uTerm

/// 两端共用的「尺寸停稳再提交」状态机（纯逻辑，不挂视图）。
@MainActor
final class TerminalResizeSettlerTests: XCTestCase {
    private typealias Target = TerminalResizeSettler.Target

    private let small = Target(size: CGSize(width: 400, height: 300))
    private let large = Target(size: CGSize(width: 800, height: 600))
    private let other = Target(size: CGSize(width: 640, height: 480))

    private func decide(_ settler: TerminalResizeSettler,
                        target: Target?, current: Target,
                        firstMount: Bool = false, settled: Bool = false,
                        onSettled: @escaping @MainActor () -> Void = {}) -> TerminalResizeSettler.Decision {
        settler.decide(target: target, current: current, isFirstMount: firstMount,
                       settled: settled, onSettled: onSettled)
    }

    func test_first_mount_commits_immediately() {
        let settler = TerminalResizeSettler()
        XCTAssertEqual(decide(settler, target: large, current: small, firstMount: true), .commit)
        XCTAssertNil(settler.held)
    }

    func test_already_at_target_commits() {
        let settler = TerminalResizeSettler()
        XCTAssertEqual(decide(settler, target: large, current: large), .commit)
    }

    func test_new_size_holds_then_settles() async {
        let settler = TerminalResizeSettler(delay: .milliseconds(20))
        let fired = expectation(description: "settled")
        XCTAssertEqual(decide(settler, target: large, current: small) { fired.fulfill() }, .hold(started: true))
        XCTAssertEqual(settler.held, large)
        await fulfillment(of: [fired], timeout: 2)
        XCTAssertEqual(decide(settler, target: large, current: small, settled: true), .commit)
        XCTAssertNil(settler.held)
    }

    /// 同一个目标反复 layout 不重启计时；换了目标才顺延。
    func test_repeated_same_target_does_not_restart_timer() {
        let settler = TerminalResizeSettler(delay: .seconds(60))
        XCTAssertEqual(decide(settler, target: large, current: small), .hold(started: true))
        XCTAssertEqual(decide(settler, target: large, current: small), .hold(started: false))
        XCTAssertEqual(decide(settler, target: other, current: small), .hold(started: true))
        XCTAssertEqual(settler.held, other)
        settler.cancel()
    }

    /// 连续拖动：中途的目标都被顺延掉，只有最后停住的那个回调一次。
    func test_superseded_targets_never_fire() async throws {
        let settler = TerminalResizeSettler(delay: .milliseconds(30))
        var fired: [CGSize] = []
        _ = decide(settler, target: large, current: small) { fired.append(CGSize(width: 800, height: 600)) }
        _ = decide(settler, target: other, current: small) { fired.append(CGSize(width: 640, height: 480)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fired, [CGSize(width: 640, height: 480)])
    }

    /// 变过去又变回原尺寸：等着的那次取消，直接按原尺寸提交，不碰缓冲区。
    func test_returning_to_current_size_cancels_hold() async throws {
        let settler = TerminalResizeSettler(delay: .milliseconds(30))
        var fired = false
        _ = decide(settler, target: large, current: small) { fired = true }
        XCTAssertEqual(decide(settler, target: small, current: small), .commit)
        XCTAssertNil(settler.held)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(fired)
    }

    func test_no_target_cancels_hold() async throws {
        let settler = TerminalResizeSettler(delay: .milliseconds(30))
        var fired = false
        _ = decide(settler, target: large, current: small) { fired = true }
        XCTAssertEqual(decide(settler, target: nil, current: small), .cancel)
        XCTAssertNil(settler.held)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(fired)
    }

    /// iOS 跟字号：尺寸不变、字号变了也要等；字号差 0.1pt 以内算没变。
    func test_font_size_participates_with_tolerance() {
        let settler = TerminalResizeSettler(delay: .seconds(60))
        let size = CGSize(width: 390, height: 600)
        XCTAssertEqual(decide(settler, target: Target(size: size, fontSize: 12),
                              current: Target(size: size, fontSize: 12.05)), .commit)
        XCTAssertEqual(decide(settler, target: Target(size: size, fontSize: 13),
                              current: Target(size: size, fontSize: 12)), .hold(started: true))
        settler.cancel()
    }
}
