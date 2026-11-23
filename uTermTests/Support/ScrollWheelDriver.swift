import AppKit

extension NSScrollView {
    /// 触控板式的一次滚动：began → 一串 changed → ended，事件直接交给这个滚动视图。`up` 是往上翻多少点。
    ///
    /// 用真的滚轮事件而不是直接挪 clip view：SwiftUI 的 `ScrollView` 停在底部（`defaultScrollAnchor(.bottom)`）时，
    /// 直接挪的位置下一次更新就被它拽回去，而且 `onScrollPhaseChange` 收不到，界面以为用户没动。
    @MainActor
    func simulateTrackpadScroll(up: Int, step: Int32 = 40) async throws {
        func post(_ delta: Int32, phase: Int64) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: delta, wheel2: 0, wheel3: 0) else { return }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            if let ns = NSEvent(cgEvent: event) { scrollWheel(with: ns) }
        }
        post(0, phase: 1)   // began
        for _ in 0..<max(1, up / Int(step)) {
            try await Task.sleep(for: .milliseconds(8))
            post(step, phase: 2)   // changed
        }
        try await Task.sleep(for: .milliseconds(8))
        post(0, phase: 4)   // ended
    }
}
