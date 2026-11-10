import GhosttyTerminal
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// 终端在什么时候画、画几次。挂在真实 scene 的窗口上：没有 scene 的窗口一次都不画，读数全是 0。
///
/// 换引擎之前这里数的是 SwiftTerm 的 `draw(_:)`（主线程 CoreGraphics），核的是几条本地补丁：滚动的输出每拍只画一次、
/// 有积压时跳过中间帧、手动滚动当场重绘。GhosttyKit 的画面由渲染线程按 vsync 交帧，解析也不在主线程上，
/// 那几条的前提（主线程一拍喂多少、画不画由 `setNeedsDisplay` 的节流决定）不存在了；留下来、新引擎上仍然成立的
/// 是「有输出才画、画得不比屏幕刷新更勤、不在屏上不画」。数的是 `GhosttyPresentLog`（引擎每交一帧记一次）。
@MainActor
final class TerminalDrawCountTests: XCTestCase {
    private var window: UIWindow?
    private static let controller = GhosttyTerminalBridge.makeController(
        fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))

    override func tearDown() async throws {
        window?.subviews.forEach { $0.removeFromSuperview() }
        window?.isHidden = true
        window = nil
    }

    private func hostedTerminal() async throws -> (GhosttyTerminalBridge, MTerminalContainerView) {
        let window = try makeSpikeWindow(size: CGSize(width: 400, height: 600))
        self.window = window
        let bridge = GhosttyTerminalBridge(controller: Self.controller)
        let container = MTerminalContainerView(terminal: bridge, fontSize: 11)
        container.frame = window.bounds
        window.addSubview(container)
        container.layoutIfNeeded()
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.isSurfaceReady && bridge.router.isFeedingSurface
        }
        XCTAssertTrue(ready, "surface 没就绪")
        GhosttyPresentLog.installIfPossible()
        // 等首帧、尺寸同步那几帧过去。
        try await Task.sleep(for: .milliseconds(400))
        return (bridge, container)
    }

    /// 喂若干拍，每拍之间留够出帧时间，返回期间交了几帧、用了多久。
    private func presentsWhileFeeding(_ bridge: GhosttyTerminalBridge, ticks: Int) async throws -> (count: Int, seconds: Double) {
        GhosttyPresentLog.reset()
        let started = CACurrentMediaTime()
        for tick in 0..<ticks {
            bridge.feed(Data(String(repeating: "line \(tick)\r\n", count: 80).utf8))
            try await Task.sleep(for: .milliseconds(40))
        }
        return (GhosttyPresentLog.read().times.count, CACurrentMediaTime() - started)
    }

    /// 滚动的输出会画，而且交帧不比屏幕刷新更勤（每个 vsync 最多一帧）。
    func testScrollingOutputPresentsNoFasterThanTheDisplay() async throws {
        let (bridge, _) = try await hostedTerminal()

        let (count, seconds) = try await presentsWhileFeeding(bridge, ticks: 10)

        let refresh = Double(window?.screen.maximumFramesPerSecond ?? 120)
        print("DRAWCOUNT scrolling presents=\(count) seconds=\(String(format: "%.2f", seconds)) refresh=\(refresh)")
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThanOrEqual(Double(count), seconds * refresh + 4)
    }

    /// 没有输出、光标不闪时不交帧：安静的终端不该占着渲染。
    func testQuietTerminalStopsPresenting() async throws {
        let (bridge, _) = try await hostedTerminal()
        // 稳定块光标（DECSCUSR 2），之后不再有输出。
        bridge.feed(Data("\u{1B}[2 q$ ".utf8))
        try await Task.sleep(for: .milliseconds(600))

        GhosttyPresentLog.reset()
        try await Task.sleep(for: .seconds(1))
        let quiet = GhosttyPresentLog.read().times.count

        print("DRAWCOUNT quiet presents=\(quiet)")
        XCTAssertLessThanOrEqual(quiet, 2, "安静的终端一秒里还在交帧")
    }

    func testOffScreenTerminalDoesNotPresent() async throws {
        let (bridge, container) = try await hostedTerminal()
        container.isOnScreen = false

        let (count, _) = try await presentsWhileFeeding(bridge, ticks: 5)

        XCTAssertEqual(count, 0)
    }

    /// 隐藏期间的输出在露出来时补上。
    func testShowingTerminalPaintsWhatItMissed() async throws {
        let (bridge, container) = try await hostedTerminal()
        container.isOnScreen = false
        _ = try await presentsWhileFeeding(bridge, ticks: 2)

        GhosttyPresentLog.reset()
        container.isOnScreen = true
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertGreaterThan(GhosttyPresentLog.read().times.count, 0)
        bridge.session.waitForPendingOutput()
        XCTAssertTrue(bridge.session.readViewportText()?.contains("line 1") == true)
    }

    /// 换引擎之前的三条：「还有积压时不画中间帧，喂完立刻画最后一帧」（`feedPaced(backlogged:)`）、
    /// 「手动滚动照常重绘」、「滚动那一帧里有输出排队时当场画、不重复画」（SwiftTerm 补丁 #14 / #21 的显示节流）。
    /// 它们测的是 SwiftTerm 主线程绘制的节流逻辑，GhosttyKit 没有这层（渲染线程每个 vsync 看一次有没有变化）。
    /// 新引擎上「边输出边滚不丢帧、不跳」由 `TerminalScrollWhileOutputProbeTests` 与 `GhosttyScrollEdgeTests` 核。
    func testDisplayThrottleCasesAreGoneWithSwiftTerm() throws {
        throw XCTSkip("SwiftTerm 的显示节流（feedPaced / displayThrottle）随引擎一起删了；见用例注释里指向的等价用例")
    }
}
