import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// 程序抓了鼠标（Claude 的全屏界面、tmux / vim 开 mouse）时，单指甩一下松手之后还有没有惯性。
///
/// 这种情况下拖动不滚视口：GhosttyKit 把位移按像素交给引擎，引擎每攒够一行高就给程序报一次滚轮
///（SGR 1006：`ESC [ < 64 / 65 ; 列 ; 行 M`），画面由程序自己重画。松手后的惯性就是「按衰减的速度接着报滚轮」。
/// 起因：user 在 Duo 上滚 Claude 的全屏界面，手指一离开屏幕就停。上游在松手那一步把「开着内联选区、程序抓着鼠标」
/// 拦掉了，不起惯性；规则与改法见 `UITerminalView+Scroll.swift`。
///
/// 量法：读会话的 write 回调（程序会收到的字节），数滚轮报告、记下每一条到的时刻。
/// 手势和 `GhosttyScrollEdgeTests` 一样走伪造的 `UIPanGestureRecognizer`，直接调 `handleTouchScrollGesture:`。
@MainActor
final class GhosttyCapturedMomentumTests: XCTestCase {
    /// UIScrollView `.normal` 减速率（每毫秒 0.998）折成的指数速率，1/s。
    private static let decayRate = -log(0.998) * 1000

    override func setUp() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
        let deadline = CACurrentMediaTime() + 10
        while CACurrentMediaTime() < deadline,
              !UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        UTermScrollTrace.programMomentumTravel = UTermScrollTrace.defaultProgramMomentumTravel
    }

    override func tearDown() async throws {
        UTermScrollTrace.programMomentumTravel = UTermScrollTrace.defaultProgramMomentumTravel
    }

    // MARK: 夹具

    /// 程序收到的滚轮报告条数。
    private struct Wheel: Equatable {
        var up = 0, down = 0, sideways = 0
        var vertical: Int { up + down }
    }

    @MainActor
    private final class Rig {
        let host: GhosttyProbeHost
        let pan = EdgeFakePan()
        /// 行高，pt。
        let cellPt: CGFloat

        init(host: GhosttyProbeHost, cellPt: CGFloat) {
            self.host = host
            self.cellPt = cellPt
        }

        var view: MGhosttyTerminalView { host.view }
        var isCoasting: Bool { view.uTermScrollState.isGliding }
        /// 这段惯性慢到多少 pt/s 就停：程序一行一行地动，两行相隔超过 0.15 s 就不再发（见 `UITerminalView+Scroll.swift`）。
        var stopSpeed: CGFloat { max(50, cellPt / 0.15) }

        func begin() { send(.began) }
        func move(_ dy: CGFloat) { send(.changed, dy: dy) }
        func end(velocity: CGPoint) { send(.ended, velocity: velocity) }

        private func send(_ state: UIGestureRecognizer.State, dy: CGFloat = 0, velocity: CGPoint = .zero) {
            pan.fakeState = state
            pan.fakeTranslation = CGPoint(x: 0, y: dy)
            pan.fakeVelocity = velocity
            _ = view.perform(NSSelectorFromString("handleTouchScrollGesture:"), with: pan)
        }

        /// 到现在为止程序收到的滚轮报告。
        var wheel: Wheel {
            let text = String(decoding: (host.bridge.inputLog ?? []).reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
            var out = Wheel()
            for part in text.components(separatedBy: "\u{1B}[<").dropFirst() {
                guard let button = Int(part.prefix { $0.isNumber }) else { continue }
                switch button {
                case 64: out.up += 1
                case 65: out.down += 1
                case 66, 67: out.sideways += 1
                default: break
                }
            }
            return out
        }
    }

    /// 一台抓着鼠标的终端。`alternateScreen`：进备用屏（全屏程序）；否则留在主屏，先喂够回滚（视口本来滚得动）。
    private func makeRig(alternateScreen: Bool) async throws -> Rig {
        let host = try GhosttyProbeHost(size: CGSize(width: 440, height: 600))
        try await host.waitUntilReady()
        XCTAssertTrue(host.view.responds(to: NSSelectorFromString("handleTouchScrollGesture:")), "GhosttyKit 的拖动处理 selector 变了")
        var text = ""
        if alternateScreen {
            text += "\u{1B}[?1049h\u{1B}[H"
            for row in 1 ... max(1, host.grid.rows - 1) { text += "row \(row)\r\n" }
        } else {
            for row in 1 ... 300 { text += "line \(row)\r\n" }
        }
        // 1000 = 按键上报（滚轮也算按键），1006 = SGR 编码。
        text += "\u{1B}[?1000h\u{1B}[?1006h"
        host.feedAndWait(text)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(host.view.isMouseCaptured, "喂了 ?1000h 之后程序应当抓着鼠标")
        let scale = host.view.window?.screen.nativeScale ?? 3
        let cell = try XCTUnwrap(host.view.uTermCellPixels)
        host.bridge.inputLog = []
        // 生产默认：单指滚动归系统滚动；程序抓着鼠标时它让位给自写的拖动（这里测的就是那条路径）。
        UTermScrollTrace.usesSystemScrolling = true
        let rig = Rig(host: host, cellPt: cell.height / scale)
        rig.pan.fakeLocation = CGPoint(x: 220, y: 300)
        return rig
    }

    /// 手指推 `steps` 步、每步 `dy` pt（负 = 往上推），一帧一步；等拖动那几条报告到齐，返回到齐时的条数。
    private func drag(_ rig: Rig, dy: CGFloat, steps: Int = 10) async throws -> Wheel {
        rig.begin()
        for _ in 0 ..< steps {
            rig.move(dy)
            try await Task.sleep(for: .milliseconds(9))
        }
        try await Task.sleep(for: .milliseconds(200))
        return rig.wheel
    }

    /// 松手之后逐帧记：离松手多久、又到了几条竖向滚轮、惯性还在不在跑。惯性停了再等 `tail` 秒收尾。
    private func record(_ rig: Rig, since liftAt: CFTimeInterval, baseline: Wheel, limit: Double = 8, tail: Double = 0.5)
        async throws -> (samples: [(t: Double, count: Int)], coastedFor: Double?)
    {
        var samples: [(t: Double, count: Int)] = []
        var stoppedAt: Double?
        while CACurrentMediaTime() - liftAt < limit {
            try await Task.sleep(for: .milliseconds(8))
            let t = CACurrentMediaTime() - liftAt
            samples.append((t, rig.wheel.vertical - baseline.vertical))
            if stoppedAt == nil, !rig.isCoasting { stoppedAt = t }
            if let stoppedAt, t - stoppedAt > tail { break }
        }
        return (samples, stoppedAt)
    }

    /// 以 `speed` pt/s 松手，滑到 `stopSpeed` 为止，要报多少行、花多久。减速率 = `.normal` ÷ `programMomentumTravel`。
    private func expectation(_ rig: Rig, speed: CGFloat) -> (rows: Double, seconds: Double) {
        let stop = Double(rig.stopSpeed)
        let rate = Self.decayRate / UTermScrollTrace.programMomentumTravel
        return ((Double(speed) - stop) / rate / Double(rig.cellPt), log(Double(speed) / stop) / rate)
    }

    // MARK: 用例

    /// 甩一下松手：滚轮报告按衰减的速度接着来，条数对得上按设定的远近滑出去的距离，方向和拖动一致，视口不动。
    /// `travel`：相对 UIScrollView `.normal` 滑多远；nil = 默认值。
    private func checkFling(alternateScreen: Bool, travel: Double? = nil) async throws {
        if let travel { UTermScrollTrace.programMomentumTravel = travel }
        let rig = try await makeRig(alternateScreen: alternateScreen)
        defer { rig.host.close() }
        let barBefore = rig.host.scrollbar
        let dragged = try await drag(rig, dy: -12)
        XCTAssertGreaterThan(dragged.down + dragged.up, 0, "抓鼠标时拖动应当在报滚轮")
        XCTAssertTrue(dragged.up == 0 || dragged.down == 0, "拖动只往一个方向推，报告却两个方向都有：\(dragged)")

        let speed: CGFloat = 1500
        let liftAt = CACurrentMediaTime()
        rig.end(velocity: CGPoint(x: 0, y: -speed))
        XCTAssertTrue(rig.isCoasting, "松手速度 \(speed) pt/s，应当起惯性")
        let run = try await record(rig, since: liftAt, baseline: dragged)
        let after = rig.wheel
        let coasted = after.vertical - dragged.vertical
        let want = expectation(rig, speed: speed)
        print("CAPTURED-MOMENTUM travel=\(UTermScrollTrace.programMomentumTravel) alt=\(alternateScreen) cell=\(String(format: "%.2f", rig.cellPt))pt drag=\(dragged) "
            + "coasted=\(coasted) rows (want \(String(format: "%.1f", want.rows))) "
            + "for=\(run.coastedFor.map { String(format: "%.2f", $0) } ?? "-")s (want \(String(format: "%.2f", want.seconds)))")

        XCTAssertGreaterThanOrEqual(Double(coasted), want.rows * 0.85 - 1, "松手后报的滚轮太少（惯性没起或者停早了）")
        XCTAssertLessThanOrEqual(Double(coasted), want.rows * 1.15 + 1, "松手后报的滚轮太多")
        // 方向：和拖动同一个键，没有横向的。
        if dragged.down > 0 { XCTAssertEqual(after.up, 0, "惯性往反方向报了滚轮") } else { XCTAssertEqual(after.down, 0, "惯性往反方向报了滚轮") }
        XCTAssertEqual(after.sideways, 0, "竖着甩不该有横向滚轮")

        // 时长：停得不早也不拖。
        let coastedFor = try XCTUnwrap(run.coastedFor, "惯性一直没停")
        XCTAssertGreaterThan(coastedFor, want.seconds * 0.6)
        XCTAssertLessThan(coastedFor, want.seconds * 1.6 + 0.3)
        // 越来越慢：前半程报的远多于后半程（指数衰减下约 4 : 1）。
        let half = coastedFor / 2
        let firstHalf = run.samples.last { $0.t <= half }?.count ?? 0
        XCTAssertGreaterThan(firstHalf, (coasted - firstHalf) * 2, "滚轮报告没有越来越稀：前半程 \(firstHalf) 条，后半程 \(coasted - firstHalf) 条")
        // 停了就是停了：之后那 0.5 s 一条不再来。
        let atStop = run.samples.first { $0.t >= coastedFor + 0.1 }?.count ?? coasted
        XCTAssertEqual(coasted, atStop, "惯性停下之后还有滚轮报告")

        // 视口没动：位移全交给了程序。
        XCTAssertEqual(rig.host.scrollbar?.offset, barBefore?.offset, "程序抓着鼠标时视口不该滚")
        XCTAssertEqual(rig.view.uTermScrollState.overscrollPixels, 0)
        XCTAssertFalse(rig.view.uTermScrollState.isBouncing)
    }

    func testFlingKeepsReportingWheelAfterLiftOnAlternateScreen() async throws {
        try await checkFling(alternateScreen: true)
    }

    func testFlingKeepsReportingWheelAfterLiftOnPrimaryScreen() async throws {
        try await checkFling(alternateScreen: false)
    }

    /// 距离跟着 `programMomentumTravel` 走：和普通滚动一样远、一半（默认的四分之一由上面两条核），条数各自对得上。
    func testTravelSettingScalesDistance() async throws {
        try await checkFling(alternateScreen: true, travel: 1)
        try await checkFling(alternateScreen: true, travel: 0.5)
    }

    /// 慢慢抬手（比「停」那条线还慢）：不起惯性，一条滚轮都不多报。
    func testSlowLiftDoesNotCoast() async throws {
        let rig = try await makeRig(alternateScreen: true)
        defer { rig.host.close() }
        let dragged = try await drag(rig, dy: -6)
        rig.end(velocity: CGPoint(x: 0, y: -rig.stopSpeed * 0.8))
        XCTAssertFalse(rig.isCoasting, "抬手速度 \(rig.stopSpeed * 0.8) pt/s 低于停下的速度线 \(rig.stopSpeed)，不该起惯性")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(rig.wheel, dragged, "没起惯性却又报了滚轮")
    }

    /// 惯性途中手指落下：当场停，之后不再报。
    func testTouchDownStopsCoasting() async throws {
        UTermScrollTrace.programMomentumTravel = 1
        let rig = try await makeRig(alternateScreen: true)
        defer { rig.host.close() }
        let dragged = try await drag(rig, dy: -12)
        rig.end(velocity: CGPoint(x: 0, y: -3000))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(rig.isCoasting, "3000 pt/s 甩出去 0.3 s 后惯性应当还在")
        XCTAssertGreaterThan(rig.wheel.vertical, dragged.vertical, "惯性途中应当在报滚轮")

        rig.view.uTermTouchDownDuringMomentum()
        XCTAssertFalse(rig.isCoasting, "手指落下后惯性应当当场停")
        try await Task.sleep(for: .milliseconds(150))
        let stopped = rig.wheel
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(rig.wheel, stopped, "手指落下之后还有滚轮报告")
    }

    /// 惯性途中程序放开了鼠标（退出全屏界面）：惯性到此为止，剩下的速度不能拿去滚视口。
    /// 往下甩（往回滚方向）：放开之后要是还在滑，主屏的回滚就会被带着滚上去。
    func testCoastingEndsWhenProgramReleasesMouse() async throws {
        UTermScrollTrace.programMomentumTravel = 1
        let rig = try await makeRig(alternateScreen: false)
        defer { rig.host.close() }
        let barBefore = try XCTUnwrap(rig.host.scrollbar)
        _ = try await drag(rig, dy: 12)
        rig.end(velocity: CGPoint(x: 0, y: 3000))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(rig.isCoasting, "3000 pt/s 甩出去 0.3 s 后惯性应当还在")

        rig.host.feedAndWait("\u{1B}[?1000l\u{1B}[?1006l")
        XCTAssertFalse(rig.host.view.isMouseCaptured)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(rig.isCoasting, "程序放开鼠标后惯性应当停")
        let released = rig.wheel
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(rig.wheel, released)
        XCTAssertEqual(rig.host.scrollbar?.offset, barBefore.offset, "程序放开鼠标后，剩下的惯性把视口带着滚了")
        XCTAssertTrue(rig.view.uTermScrollState.isAtRest, "\(rig.view.uTermScrollState)")
    }

    /// 斜着甩：只留主方向，横向那点速度不该攒成横向滚轮报给程序。
    func testSidewaysDriftIsNotReported() async throws {
        let rig = try await makeRig(alternateScreen: true)
        defer { rig.host.close() }
        let dragged = try await drag(rig, dy: -12)
        let liftAt = CACurrentMediaTime()
        rig.end(velocity: CGPoint(x: 900, y: -2000))
        let run = try await record(rig, since: liftAt, baseline: dragged)
        XCTAssertNotNil(run.coastedFor, "惯性一直没停")
        let after = rig.wheel
        XCTAssertGreaterThan(after.vertical, dragged.vertical, "斜着甩也该有竖向惯性")
        XCTAssertEqual(after.sideways, 0, "横向那点速度被报成了横向滚轮")
    }
}
