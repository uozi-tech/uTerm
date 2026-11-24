import Foundation
import Synchronization
import USSHKit

/// shell 报了退出状态之后，终端会话什么时候结束。
///
/// 退出状态不受流控：慢链路上它会先于还卡在 SSH 窗口后面的最后一段输出到达（`cat big.log; exit`、
/// `make 2>&1 | tail -200; exit` 的那一截正是用户要看的）。所以不是「退出后 500 ms 就停」，而是**输出安静了**
/// `idle` 才停，每到一块输出重新计时；同时最多等 `cap`，后台进程占着伪终端一直在打字时会话也照样结束
/// （`sleep 1000 &; exit`、`yes &; exit`，这一条最初就是为它加的）。
/// 通道直接关了（正常退出）不经过这里：输出流自己结束。
nonisolated final class RemoteExitDrain: Sendable {
    static let idle = Duration.milliseconds(500)
    static let cap = Duration.seconds(5)

    private let lastChunk = Mutex<ContinuousClock.Instant?>(nil)
    private let idle: Duration
    private let cap: Duration

    init(idle: Duration = RemoteExitDrain.idle, cap: Duration = RemoteExitDrain.cap) {
        self.idle = idle
        self.cap = cap
    }

    /// 输出泵每收到一块调一次。
    func noteChunk() {
        let now = ContinuousClock.now
        lastChunk.withLock { $0 = now }
    }

    /// 远端报了退出、且输出安静了 `idle`（或退出后过了 `cap`）时返回；没报退出状态就通道关了的话一直等到被取消。
    func waitForQuietAfterExit(of shell: SSHShellHandle) async {
        guard await shell.exitStatusReported() != nil else {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            return
        }
        await waitForQuiet(since: .now)
    }

    /// 从 `exitedAt` 起算：输出安静 `idle` 或到了 `exitedAt + cap` 就返回。被取消也返回。
    func waitForQuiet(since exitedAt: ContinuousClock.Instant) async {
        let hardStop = exitedAt + cap
        while !Task.isCancelled {
            let activity = max(exitedAt, lastChunk.withLock { $0 } ?? exitedAt)
            let deadline = min(activity + idle, hardStop)
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(until: deadline, clock: .continuous)
        }
    }
}
