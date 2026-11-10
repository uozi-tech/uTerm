import Foundation
import GhosttyTerminal

/// 新 surface 的网格报告要不要认（两端共用，`TerminalSurfaceLink` 持有）。
///
/// 新 surface 的终端先按出生时的默认网格报一次 resize（Mac 上按 800×600 px 算出约 53×21，iOS 上 30×10 这种），再报真实的。
/// 那一次不能让影子终端跟：影子缩到默认网格再放回来，备用屏（全屏程序）的内容就被裁掉了，而网格最终没变时程序收不到
/// SIGWINCH、不会重画。而且这次报告可能早于「surface 建好了」的回调（surface 一建好 IO 线程就在跑）。
/// resize 回调在 IO 线程上来、影子要当场跟着改，所以这道判断是线程安全的、不绕主线程：
/// - surface 拆掉时就关闸（不能等新的建好再关）；
/// - surface 刚建好：只认和视图算出来的网格（主线程上 `expect`）一致的那一次，之前的拦下；
/// - 认过一次之后：之后的每一次都认（正常的尺寸变化）；
/// - 兜底 `settle()`：等不到对得上的那一次时由宿主开闸。
///
/// 一开始闸是关的：第一个 surface 的默认网格报告也可能早于「建好了」的回调。
nonisolated final class TerminalSurfaceGridGate: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var expected: (cols: UInt16, rows: UInt16)?
    private var held: InMemoryTerminalViewport?

    /// surface 拆掉了：从这一刻起不认任何报告。
    func surfaceDetached() {
        lock.withLock {
            settled = false
            expected = nil
            held = nil
        }
    }

    /// surface 建好了。已经拦下的报告留着：视图算出网格之后（`expect`）对得上就认。
    func surfaceAttached() {
        lock.withLock {
            settled = false
            expected = nil
        }
    }

    /// IO 线程：这次报告认不认。
    func admits(_ viewport: InMemoryTerminalViewport) -> Bool {
        lock.withLock {
            if settled { return true }
            if let expected, expected.cols == viewport.columns, expected.rows == viewport.rows {
                settled = true
                held = nil
                return true
            }
            held = viewport
            return false
        }
    }

    /// 主线程：视图算出来的网格。之前拦下的那次正好是它，就交回去让调用方认。
    func expect(cols: Int, rows: Int) -> InMemoryTerminalViewport? {
        lock.withLock {
            guard !settled else { return nil }
            expected = (UInt16(clamping: cols), UInt16(clamping: rows))
            guard let held, held.columns == expected?.cols, held.rows == expected?.rows else { return nil }
            settled = true
            self.held = nil
            return held
        }
    }

    /// 兜底开闸：之后的报告都认；返回拦下的最后一次（有的话调用方要认下它）。
    func settle() -> InMemoryTerminalViewport? {
        lock.withLock {
            guard !settled else { return nil }
            settled = true
            defer { held = nil }
            return held
        }
    }
}

/// 终端画面（surface）的保留：不在屏上多久之后放掉它（交换链、帧缓冲、引擎里的回滚；每个十几 MB），露出来时重建、
/// 由影子终端回放。两端共用。
@MainActor
final class TerminalSurfaceRetention {
    nonisolated static let hiddenReleaseDelay: Duration = .seconds(60)

    /// 不在屏上多久放掉（测试里改短）。
    var delay: Duration = TerminalSurfaceRetention.hiddenReleaseDelay
    private var task: Task<Void, Never>?

    /// 离开屏幕：隔 `delay` 还没回来（没被 `cancel`）就调 `release`。之前排着的那次作废。
    func scheduleRelease(_ release: @escaping @MainActor () -> Void) {
        task?.cancel()
        let delay = delay
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            release()
        }
    }

    /// 回到屏上：不放了。
    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
