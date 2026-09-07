import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// `help(whenHovering:_:)` 的**求值**闸门。
///
/// 门控挡的是 tooltip 区域，挡不住实参求值：形参是 `String` 的那一版里，
/// `"最近连接失败：\(issue)"`、`"累计 ↑ \(fmt(t.up)) · ↓ \(fmt(t.down))"`
/// 这些插值串在**每一次 body 求值**里都要拼一遍，不悬停的行也一样付账
/// （`GlobalForwardRow` 一行挂 5 处、`TunnelRow` 4 处，上千行就是上千遍）。
///
/// 改成 `@autoclosure () -> String` 之后只有真悬停的那一行求值。
/// 这条用例就是钉这件事：传一个带计数副作用的表达式，
/// `whenHovering: false` 时计数必须是 **0**。
@MainActor
final class HoverGatedHelpTests: XCTestCase {

    /// 计数用的副作用容器。`nonisolated(unsafe)` 不需要——整个用例都在主线程。
    @MainActor
    final class Counter {
        var evaluations = 0
        func text(_ s: String) -> String {
            evaluations += 1
            return s
        }
    }

    private struct Probe: View {
        let counter: Counter
        let hovering: Bool
        var body: some View {
            Text("row")
                .help(whenHovering: hovering, counter.text("端点 10.0.0.1:22"))
        }
    }

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func render(_ view: some View) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 200, height: 40)))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        let window = ProbeWindow.make(contentRect: host.frame,
                                      styleMask: [.titled],
                                      contentView: host,
                                      placement: .offScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    func testTextIsNotEvaluatedWhenNotHovering() {
        defer { closeAllWindows() }
        let counter = Counter()
        render(Probe(counter: counter, hovering: false))
        XCTAssertEqual(counter.evaluations, 0,
                       "不悬停时 tooltip 文案一次都不该求值 —— 求了 \(counter.evaluations) 次，"
                       + "说明 `help(whenHovering:_:)` 的形参又变回了非 autoclosure 的 `String`")
    }

    func testTextIsEvaluatedWhenHovering() {
        defer { closeAllWindows() }
        let counter = Counter()
        render(Probe(counter: counter, hovering: true))
        XCTAssertGreaterThan(counter.evaluations, 0,
                             "悬停时必须求值一次并把 tooltip 挂上去")
    }

    /// 空串守卫仍在：悬停但文案为空时不挂 tooltip（挂了会弹一个空气泡）。
    func testEmptyTextStillSkipsHelp() {
        defer { closeAllWindows() }
        struct EmptyProbe: View {
            var body: some View {
                Text("row").help(whenHovering: true, "")
            }
        }
        render(EmptyProbe())   // 只要不炸：空串走 `self` 分支
    }
}
