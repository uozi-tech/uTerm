import Foundation
import Synchronization

/// 一次贴图 / 粘贴走到哪了：读出来（剪贴板 / 相册）→ 压缩 → 发出去 → 等对方处理。两端共用；
/// iOS 拿它画终端键盘条上方与远程桌面顶上的进度条。
///
/// 每段有自己的 0...1，合成一条总进度（`overall`）：读和压缩在本机，快；发送走网络，占大头。
/// 某段量不出比例时（远控 Mac 的贴图是一条消息，发完才有回调）就停在这段的起点，结束时跳到下一段。
nonisolated struct PasteProgress: Equatable, Sendable {
    enum Phase: Int, Sendable {
        case reading, encoding, sending, finishing
    }

    let phase: Phase
    /// 本段完成了多少，0...1。
    let fraction: Double

    init(_ phase: Phase, fraction: Double = 0) {
        self.phase = phase
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }

    static func sending(_ done: Int, of total: Int) -> PasteProgress {
        PasteProgress(.sending, fraction: total > 0 ? Double(done) / Double(total) : 1)
    }

    /// 各段在总进度里占的区间。
    private var span: (start: Double, end: Double) {
        switch phase {
        case .reading: return (0, 0.2)
        case .encoding: return (0.2, 0.3)
        case .sending: return (0.3, 0.95)
        case .finishing: return (0.95, 1)
        }
    }

    var overall: Double { span.start + (span.end - span.start) * fraction }

    var label: String {
        switch phase {
        case .reading: return String(localized: "正在读取…")
        case .encoding: return String(localized: "正在压缩图片…")
        case .sending: return String(localized: "正在发送…")
        case .finishing: return String(localized: "正在等待对方处理…")
        }
    }

    var note: PasteNote { PasteNote(text: label, progress: overall) }
}

/// 界面上那条提示：进行中带进度条，出结果之后只剩一句话。
nonisolated struct PasteNote: Equatable, Sendable {
    var text: String
    /// 0...1；nil = 不是进行中（结果、错误、别的提示）。
    var progress: Double?
}

/// 进度经 task-local 一路往下传（同 `IOActivity.pulse`）：读剪贴板、压缩、各个后端的上传在哪报都行，
/// `TerminalImageReceiving.deliverImage` 之类的签名不用为它改。没人听的时候（Mac 上、测试里）什么都不做。
nonisolated enum PasteProgressReporter {
    @TaskLocal static var sink: (@Sendable (PasteProgress) -> Void)?

    static func report(_ progress: PasteProgress) {
        sink?(progress)
    }
}

/// 把任意线程上报来的进度送回主线程给界面。太密的不送（SFTP 每 32 KB 回一次确认，4 MB 就是一百多次界面刷新），
/// 往回退的不送（并发的回调先后不定）。送主线程那一步在锁里排队，到主线程时的先后与这里放行的先后一致。
nonisolated final class PasteProgressRelay: Sendable {
    private let last = Mutex<PasteProgress?>(nil)
    private let deliver: @MainActor @Sendable (PasteProgress) -> Void

    init(_ deliver: @escaping @MainActor @Sendable (PasteProgress) -> Void) {
        self.deliver = deliver
    }

    /// 任意线程可调。
    func report(_ progress: PasteProgress) {
        last.withLock { last in
            if let last {
                guard progress.overall >= last.overall else { return }
                let samePhase = progress.phase == last.phase
                if samePhase, progress.fraction < 1, progress.overall - last.overall < 0.01 { return }
                if samePhase, progress == last { return }
            }
            last = progress
            let deliver = self.deliver
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(progress) } }
        }
    }

    /// 交给 `PasteProgressReporter.$sink.withValue` 的那个闭包。
    var sink: @Sendable (PasteProgress) -> Void {
        { [self] progress in report(progress) }
    }
}
