import AppKit
import GhosttyTerminal
import XCTest
@testable import uTerm

/// Magic Mouse 连续拨动时画面不能往回跳。
///
/// 用户实测（1090）：有回滚的标签里用 Magic Mouse 滚动，内容上下来回跳一行半行。回放真实录制
/// （`MagicMouseScrollRecording`）找到的原因：下一次手指碰上去会把上一次的惯性掐断，惯性结束那一刻画面还在高速走；
/// 停手吸附整行的规则是「离哪边近往哪边走」，近的那一边可能在反方向，于是先往回退最多半行，50–70 ms 后新的一拨
/// 又往前走。改成顺着刚才滚动的方向补到整行之后，一次拨动（拖动 + 惯性 + 吸附）里视口只朝一个方向动。
@MainActor
final class GhosttyMagicMouseScrollTests: XCTestCase {
    private var sessions: [TerminalSession] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        sessions.forEach { $0.dispose() }
        sessions = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        try await super.tearDown()
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func makeView(lines: Int) async throws -> GhosttySurfaceView {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        sessions.append(session)
        let backend = MockBackend()
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 900)
        let window = ProbeWindow.make(contentRect: rect, contentView: NSView(frame: rect), placement: .transparentOnScreen,
                                      keepsDrawing: true)
        windows.append(window)
        let container = GhosttyContainerView(surface: session.ghostty.view)
        container.isActive = true
        container.frame = NSRect(x: 0, y: 0, width: 816, height: 517)
        window.contentView?.addSubview(container)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        let live = await waitUntil(10) { session.ghostty.isLive && session.ghostty.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪")
        await session.connect(using: backend)
        var text = ""
        for n in 1 ... lines { text += "line \(n)\r\n" }
        await backend.emitOutput(Data(text.utf8))
        let fed = await waitUntil(20) { (session.ghostty.viewportText() ?? "").contains("line \(lines)") }
        XCTAssertTrue(fed, "语料没喂完")
        try? await Task.sleep(for: .milliseconds(300))
        return session.ghostty.view
    }

    /// 录制里的一个事件 → 真的 `NSEvent`（连续滚动、带 phase / momentumPhase）。
    private func event(_ e: MagicMouseScrollRecording.Event) throws -> NSEvent {
        // NSEvent.Phase 原值 → CGScrollPhase / CGMomentumScrollPhase。
        let phase: Int64 = [1: 1, 4: 2, 8: 4, 16: 8][e.phase] ?? 0
        let momentum: Int64 = [1: 1, 4: 2, 8: 3][e.momentum] ?? 0
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                       wheel1: Int32(e.deltaY), wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(e.deltaY))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// 一次拨动：从 began 到下一次 began 之前（拖动、惯性、惯性结束后的吸附都算它的）。
    private struct Stroke {
        var index: Int
        var direction: Int          // 位置的走向：+1 = 往活动区（行号变大），-1 = 往回滚
        var positions: [Int] = []   // 视口顶边在缓冲区里的像素位置（镜像：首行 × 行高 + 小数）
        var interruptedSpeed = 0    // 惯性结束前最后一个事件的位移（pt）：大 = 被下一次触碰掐断的
    }

    func testMagicMouseStrokesNeverMoveTheViewportBackwards() async throws {
        let view = try await makeView(lines: 6000)
        let cell = Int(try XCTUnwrap(view.uTermCellPixels).height)
        // 先滚到回滚中段，录制里两个方向的拨动都有余地。
        let scale = try XCTUnwrap(view.window).backingScaleFactor
        let half = Int(CGFloat(3000 * cell) / scale)
        view.scrollWheel(with: try event(.init(delayMs: 0, phase: 1, momentum: 0, deltaY: 0)))
        view.scrollWheel(with: try event(.init(delayMs: 0, phase: 4, momentum: 0, deltaY: half)))
        view.scrollWheel(with: try event(.init(delayMs: 0, phase: 8, momentum: 0, deltaY: 0)))
        let centered = await waitUntil(5) {
            guard let offset = view.uTermScrollbarOffset else { return false }
            return offset > 2000 && offset < 4000 && view.uTermScrollState.isAtRest
        }
        XCTAssertTrue(centered, "没滚到回滚中段：\(String(describing: view.uTermScrollbarOffset))")
        try? await Task.sleep(for: .milliseconds(200))

        func position() -> Int {
            let state = view.uTermScrollState
            return state.row * cell + state.fractionPixels
        }

        var strokes: [Stroke] = []
        var lastMomentumDelta = 0
        for e in MagicMouseScrollRecording.events {
            // 等到这个事件该来的时刻；等的时候每 ~2 ms 记一次位置（吸附动画就发生在这些空隙里）。
            let due = Date().addingTimeInterval(Double(e.delayMs) / 1000)
            while Date() < due {
                try? await Task.sleep(for: .milliseconds(2))
                if !strokes.isEmpty { strokes[strokes.count - 1].positions.append(position()) }
            }
            if e.phase == 1 {
                // scrollingDeltaY 为正 = 内容往下走 = 往回滚（位置变小）。方向先按 began 的位移记，后面的事件会校正。
                strokes.append(Stroke(index: strokes.count, direction: e.deltaY > 0 ? -1 : 1))
            }
            if e.momentum == 4 { lastMomentumDelta = e.deltaY }
            if e.momentum == 8, !strokes.isEmpty { strokes[strokes.count - 1].interruptedSpeed = abs(lastMomentumDelta) }
            if e.deltaY != 0, !strokes.isEmpty { strokes[strokes.count - 1].direction = e.deltaY > 0 ? -1 : 1 }
            view.scrollWheel(with: try event(e))
            if !strokes.isEmpty { strokes[strokes.count - 1].positions.append(position()) }
        }
        // 最后一次拨动之后等吸附落定。
        for _ in 0 ..< 200 {
            try? await Task.sleep(for: .milliseconds(2))
            strokes[strokes.count - 1].positions.append(position())
        }

        XCTAssertGreaterThan(strokes.count, 30, "录制没回放完")
        var problems: [String] = []
        var worst = 0
        for stroke in strokes {
            var back = 0
            for (a, b) in zip(stroke.positions, stroke.positions.dropFirst()) where (b - a) * stroke.direction < 0 {
                back += abs(b - a)
            }
            worst = max(worst, back)
            if back > 0 {
                problems.append("第 \(stroke.index) 拨（方向 \(stroke.direction > 0 ? "往下" : "往上")，惯性结束时 \(stroke.interruptedSpeed) pt/事件）往回走了 \(back) px")
            }
        }
        print("MAGIC-MOUSE 行高 \(cell) px，\(strokes.count) 拨，往回走的有 \(problems.count) 拨，最多 \(worst) px")
        XCTAssertTrue(problems.isEmpty, "一次拨动里视口往回走了（行高 \(cell) px）：\n" + problems.joined(separator: "\n"))

        // 落定之后在整行上。
        let rested = await waitUntil(2) { view.uTermScrollState.isAtRest }
        XCTAssertTrue(rested, "停手之后没吸附到整行：\(view.uTermScrollState)")
    }
}
