import SwiftUI
import XCTest
@testable import uTermMobile

/// 空闲耗电守卫：界面上「一直在动 / 一直在走表」的东西，只在画面真需要时才跑。
///
/// - SwiftUI `.repeatForever` 会把整棵视图树钉在每帧重绘上，且不看画面可不可见（macOS 实测
///   空载 30%+ CPU）；常驻动画一律走 `uTerm/Shared/Views/CAMotion.swift` 的 CA 图元。
/// - 常驻 `Timer.publish` 从视图出现起一直唤醒主线程，挂在根视图上还会每拍让整屏重求 body；
///   走表用 `.task(id:)` 按「该不该走」起停（参照 `ParRunSubtitle`）。
final class MobileIdlePowerTests: XCTestCase {

    // MARK: 并行执行页的用时计时

    func testElapsedTickerRunsOnlyWhileRunningAndOnScreen() {
        // 还在跑 + 前台 / 半遮（控制中心、App 切换器，画面仍可见）→ 走。
        XCTAssertTrue(ParElapsedTicker.shouldTick(allDone: false, phase: .active))
        XCTAssertTrue(ParElapsedTicker.shouldTick(allDone: false, phase: .inactive))
        // 退到后台（BGContinuedProcessingTask 让运行继续，但画面不可见）→ 停。
        XCTAssertFalse(ParElapsedTicker.shouldTick(allDone: false, phase: .background))
        // 全部完成：用时取 finishedAt，不再需要走表。
        XCTAssertFalse(ParElapsedTicker.shouldTick(allDone: true, phase: .active))
        // 控制器还没造好。
        XCTAssertFalse(ParElapsedTicker.shouldTick(allDone: nil, phase: .active))
    }

    func testElapsedTickerKeepsOriginalCadence() {
        // 副标题用时是三位有效数字（`12.5 s`），降频会让数字跳得更粗、看得出来：节拍钉在原来的 0.5 s。
        XCTAssertEqual(ParElapsedTicker.interval, .milliseconds(500))
    }

    // MARK: 源码守卫

    func testMobileSourcesAvoidPerpetualSwiftUIAnimationsAndTimers() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("扫的是 Mac 上的源码目录，真机读不到；在模拟器上跑")
        #endif
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uTermMobile")
        let pattern = try NSRegularExpression(pattern: #"\.repeatForever\b|Timer\.publish\s*\("#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                // 注释里提到它们（解释为什么不用）不算。
                let code = line.components(separatedBy: "//")[0]
                let range = NSRange(code.startIndex..., in: code)
                if pattern.firstMatch(in: code, range: range) != nil {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertGreaterThan(scanned, 50, "没扫到源码，路径可能不对：\(root.path)")
        XCTAssertEqual(offenders, [],
                       "常驻动画改用 CAMotion 图元（PulseDot / SpinningArc / BlinkingBar / ShimmerSweep），"
                       + "走表改用按状态起停的 .task(id:)")
    }
}
