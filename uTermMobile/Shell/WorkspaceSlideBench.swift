#if DEBUG || UTERM_BENCH
import QuartzCore
import SwiftUI

/// 调试 / 测量：工作区滑进、滑出各掉了多少帧。偏好 `WorkspaceSlideBench = <轮数>` 时启动后自动跑：
/// 第一轮开体验主机的终端，之后每轮把工作区滑进来、停 2 秒、再滑回主机页；滑进、滑出各用 CADisplayLink 记 0.8 秒
/// 的帧间隔（滑完的那一刻在 +340 ms 左右，之后的掉帧算「停稳后」）。结果写 `Documents/slide-bench.txt` 并打到标准输出。
/// 不靠外部注入触摸（vphone 里不可靠）。跑一次就清掉偏好。
@MainActor
enum WorkspaceSlideBench {
    static let key = "WorkspaceSlideBench"

    private struct Tally {
        var frames = 0, hitches = 0, hitchMs = 0.0, worstMs = 0.0
        var during = 0, after = 0
        var line: String {
            String(format: "frames %d hitches %d (during %d, after %d) hitch_ms %.1f worst_ms %.1f",
                   frames, hitches, during, after, hitchMs, worstMs)
        }
    }

    static func runIfRequested(store: MobileStore) async {
        let rounds = UserDefaults.standard.integer(forKey: key)
        guard rounds > 0 else { return }
        UserDefaults.standard.removeObject(forKey: key)
        try? await Task.sleep(for: .seconds(4))
        let fps = Double(UIScreen.main.maximumFramesPerSecond)
        let budget = 1 / fps
        let settle = WorkspaceLayer.slideSettleSeconds
        var lines = ["build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?") fps \(Int(fps)) rounds \(rounds)"]
        var totals = ["in": Tally(), "out": Tally()]

        func measure(_ name: String, round: Int, _ change: () -> Void) async {
            let recorder = FrameGapRecorder()
            recorder.start()
            try? await Task.sleep(for: .milliseconds(100))
            let start = CACurrentMediaTime()
            change()
            try? await Task.sleep(for: .milliseconds(800))
            let frames = recorder.stop().filter { $0.end > start }
            let hitches = frames.filter { $0.gap > budget * 1.5 }
            var tally = totals[name] ?? Tally()
            tally.frames += frames.count
            tally.hitches += hitches.count
            tally.hitchMs += hitches.reduce(0) { $0 + ($1.gap - budget) } * 1000
            tally.worstMs = max(tally.worstMs, (frames.map(\.gap).max() ?? 0) * 1000)
            tally.during += hitches.filter { $0.end - start <= settle }.count
            tally.after += hitches.filter { $0.end - start > settle }.count
            totals[name] = tally
            let at = hitches.map { String(format: "%+.0f:%.0f", ($0.end - start) * 1000, $0.gap * 1000) }
            lines.append("\(name) \(round) hitches \(hitches.count) at " + at.joined(separator: " "))
        }

        for round in 0..<rounds {
            await measure("in", round: round) {
                if round == 0 { store.openDemo(.terminal) } else { store.showWorkspace = true }
            }
            try? await Task.sleep(for: .seconds(2))
            await measure("out", round: round) { store.showWorkspace = false }
            try? await Task.sleep(for: .seconds(1.5))
        }
        lines.append("TOTAL in  " + (totals["in"] ?? Tally()).line)
        lines.append("TOTAL out " + (totals["out"] ?? Tally()).line)
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
