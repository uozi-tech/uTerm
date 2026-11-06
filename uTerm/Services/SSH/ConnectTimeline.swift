import Foundation
import Network
import Synchronization

/// 一次建连的分段计时：按阶段 `mark`，到终点 `finish` 打一行汇总日志。
///
/// 通过 task-local `current` 传递，建连链路上的各层（钥匙串 → 握手 → 开通道 → 首字节）
/// 不用改签名就能打点；不在计时范围内的调用拿到 nil，什么也不做。`Task {}` 会继承
/// task-local，所以 `SSHConnection` 里挂整个会话的 `sessionTask` 也打得到点。
///
/// 日志走 `AppLogger.info`，category `ssh-timing`：
///
///     log stream --predicate 'subsystem == "com.uozi.uTerm" AND category == "ssh-timing"'
///
/// 每段记的是距上一个 `mark` 的增量；`total` 是从创建到 `finish` 的总耗时，
/// 扣掉 `exclude` 的部分（探针本身的耗时不算进建连）。
nonisolated final class ConnectTimeline: Sendable {
    @TaskLocal static var current: ConnectTimeline?

    private struct State {
        var last: ContinuousClock.Instant
        var phases: [(name: String, duration: Duration)] = []
        var notes: [String] = []
        var excluded: Duration = .zero
        var finished = false
    }

    let kind: String
    let target: String
    private let start: ContinuousClock.Instant
    private let state: Mutex<State>

    init(kind: String, target: String) {
        let now = ContinuousClock.now
        self.kind = kind
        self.target = target
        self.start = now
        self.state = Mutex(State(last: now))
    }

    /// 记一段：从上一个 `mark`（或创建）到现在。
    func mark(_ phase: String) {
        let now = ContinuousClock.now
        state.withLock { state in
            guard !state.finished else { return }
            state.phases.append((phase, now - state.last))
            state.last = now
        }
    }

    /// 从上一个 `mark` 到现在的耗时不计入任何阶段，也从 `total` 里扣掉。
    func exclude() {
        let now = ContinuousClock.now
        state.withLock { state in
            guard !state.finished else { return }
            state.excluded += now - state.last
            state.last = now
        }
    }

    /// 附加一条说明（探针读数等），随汇总行一起输出。
    func note(_ text: String) {
        state.withLock { state in
            guard !state.finished else { return }
            state.notes.append(text)
        }
    }

    /// 打汇总日志。只有第一次调用生效。
    func finish(_ outcome: String = "ok") {
        let now = ContinuousClock.now
        let line: String? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            let phases = state.phases
                .map { "\($0.name)=\(Self.milliseconds($0.duration))" }
                .joined(separator: " ")
            let total = Self.milliseconds(now - start - state.excluded)
            var line = "[\(kind)] \(target) \(outcome) total=\(total) | \(phases)"
            if !state.notes.isEmpty {
                line += " | " + state.notes.joined(separator: " ")
            }
            return line
        }
        guard let line else { return }
        AppLogger.info(line, category: "ssh-timing")
    }

    static func milliseconds(_ duration: Duration) -> String {
        "\(Int((duration / .milliseconds(1)).rounded()))ms"
    }
}

/// 建连诊断探针：打开 `sshTimingProbe` 后，每次建连前先单独量 DNS 与裸 TCP 握手，
/// 用来把「握手」这一段拆成网络往返与本机开销。会多连一次 sshd 端口（握完 TCP 立即断开），
/// 所以默认关闭：
///
///     defaults write com.uozi.uTerm sshTimingProbe -bool YES
nonisolated enum ConnectProbe {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.sshTimingProbe)
    }

    /// getaddrinfo 的耗时与地址族分布，如 `dns=3ms(v4:1,v6:0)`。
    static func resolve(host: String, port: Int) async -> String {
        await Task.detached {
            let clock = ContinuousClock()
            var v4 = 0
            var v6 = 0
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let elapsed = clock.measure {
                guard getaddrinfo(host, String(port), &hints, &result) == 0 else { return }
                var cursor = result
                while let info = cursor {
                    if info.pointee.ai_family == AF_INET { v4 += 1 }
                    if info.pointee.ai_family == AF_INET6 { v6 += 1 }
                    cursor = info.pointee.ai_next
                }
                freeaddrinfo(result)
            }
            return "dns=\(ConnectTimeline.milliseconds(elapsed))(v4:\(v4),v6:\(v6))"
        }.value
    }

    /// 裸 TCP 握手到就绪的耗时（≈ 1 个往返）；超时或失败返回 nil。
    static func tcpConnect(host: String, port: Int, timeout: Duration = .seconds(5)) async -> Duration? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "uterm.connect-probe")
        let start = ContinuousClock.now
        let resumed = Mutex(false)
        let elapsed: Duration? = await withCheckedContinuation { continuation in
            let resume: @Sendable (Duration?) -> Void = { value in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume(ContinuousClock.now - start)
                case .failed, .cancelled:
                    resume(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout / .seconds(1)) { resume(nil) }
        }
        connection.cancel()
        return elapsed
    }
}

extension ServerProfile {
    /// 计时日志里标识这次建连的目标，如 `root@10.0.0.2:22 via bastion`。
    var timingTarget: String {
        let target = "\(username)@\(host):\(port)"
        guard let jumpHost else { return target }
        return "\(target) via \(jumpHost.host)"
    }
}
