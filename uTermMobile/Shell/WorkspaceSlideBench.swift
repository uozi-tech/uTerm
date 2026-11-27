#if DEBUG || UTERM_BENCH
import QuartzCore
import SwiftUI

/// 调试 / 测量：从工作区滑回主机页这一下掉了多少帧。偏好 `WorkspaceSlideBench = <轮数>` 时启动后自动跑：
/// 第一轮开体验主机的终端，之后每轮把工作区滑进来、停 2 秒、再滑回主机页，滑回时用 CADisplayLink 记 0.8 秒的帧间隔。
/// 结果写 `Documents/slide-bench.txt` 并打到标准输出。不靠外部注入触摸（vphone 里不可靠）。跑一次就清掉偏好。
@MainActor
enum WorkspaceSlideBench {
    static let key = "WorkspaceSlideBench"

    static func runIfRequested(store: MobileStore) async {
        let rounds = UserDefaults.standard.integer(forKey: key)
        guard rounds > 0 else { return }
        UserDefaults.standard.removeObject(forKey: key)
        // 对照：`WorkspaceSlideBenchResignFirst = YES` 时先收键盘、等 0.5 秒再滑。
        let resignFirst = UserDefaults.standard.bool(forKey: key + "ResignFirst")
        try? await Task.sleep(for: .seconds(4))
        let fps = Double(UIScreen.main.maximumFramesPerSecond)
        var lines = ["build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?") fps \(Int(fps)) rounds \(rounds) resignFirst \(resignFirst)"]
        var totals = (hitches: 0, frames: 0, hitchMs: 0.0, worstMs: 0.0)
        for round in 0..<rounds {
            if round == 0 { store.openDemo(.terminal) } else { store.showWorkspace = true }
            try? await Task.sleep(for: .seconds(2))
            if resignFirst {
                let responder = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                               to: nil, from: nil, for: nil)
                lines.append("resigned \(responder)")
                try? await Task.sleep(for: .milliseconds(500))
            }
            let recorder = FrameGapRecorder()
            recorder.start()
            try? await Task.sleep(for: .milliseconds(100))
            let slideStart = CACurrentMediaTime()
            store.showWorkspace = false
            try? await Task.sleep(for: .milliseconds(800))
            let frames = recorder.stop()
            let gaps = frames.map(\.gap)
            let budget = 1 / fps
            let hitches = gaps.filter { $0 > budget * 1.5 }
            let hitchMs = hitches.reduce(0) { $0 + ($1 - budget) } * 1000
            let worst = (gaps.max() ?? 0) * 1000
            totals.hitches += hitches.count
            totals.frames += gaps.count
            totals.hitchMs += hitchMs
            totals.worstMs = max(totals.worstMs, worst)
            // 每个掉帧的那一帧在滑出开始后多少毫秒结束、拖了多长。
            let at = frames.filter { $0.gap > budget * 1.5 }
                .map { String(format: "%+.0f:%.0f", ($0.end - slideStart) * 1000, $0.gap * 1000) }
            lines.append(String(format: "round %d frames %d hitches %d hitch_ms %.1f worst_ms %.1f at ",
                                round, gaps.count, hitches.count, hitchMs, worst) + at.joined(separator: " "))
            try? await Task.sleep(for: .seconds(1))
        }
        lines.append(String(format: "TOTAL frames %d hitches %d hitch_ms %.1f worst_ms %.1f",
                            totals.frames, totals.hitches, totals.hitchMs, totals.worstMs))
        let text = lines.joined(separator: "\n") + "\n"
        print(text)
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? text.write(to: docs.appendingPathComponent("slide-bench.txt"), atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
private final class FrameGapRecorder: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames: [(gap: Double, end: CFTimeInterval)] = []

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { frames.append((link.timestamp - last, link.timestamp)) }
        last = link.timestamp
    }

    func stop() -> [(gap: Double, end: CFTimeInterval)] {
        link?.invalidate()
        link = nil
        return frames
    }
}
#endif
