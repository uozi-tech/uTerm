import Foundation
import SwiftData
@testable import uTermMobile

/// 假并行执行：n 台各以 50 行/秒追加输出、跑 10 秒、可配失败台数。
///
/// ## 三种用法
///
/// 1. **执行器**（`ParallelCommandExecuting`，2026-09-08 产品侧开了缝之后的主用法）：
///    ```swift
///    let fake = MobileFakeParallelRun(config: .standard(hosts: 24), targets: hosts)
///    let controller = ParallelRunController(…, container: container, executor: fake)
///    ParallelRunView(request: req, makeController: { _ in controller }, onClose: {})
///    ```
///    真控制器跑真流程（`runLane` / `markUnreachable` / `finalize` 一条不少），
///    只是每台的 SSH 会话换成按节拍吐行的假会话 —— **整屏**因此挂得上探针。
/// 2. `emitAll()`：同步把 `duration × linesPerSecond` 行一次性发完到自己的 `states`。
///    **行数精确**，自证测试与「一次性挂 N 行有多贵」用这个。
/// 3. `start()` / `stop()`：自己的 `states` 按真实节拍长（每 20ms 一批），
///    只量模型侧成本时用。行数受调度抖动影响，只能按区间断言。
///
/// 2 / 3 产出的 `states` 与 `ParallelRunController.states` **完全同形**（同一个
/// `PServerState`、同样的 `PLine.Kind` 序列、同样的 tone / exitCode / durationMs 语义）。
@MainActor
final class MobileFakeParallelRun {

    /// 一次假并行执行的配置。
    struct Config: Sendable {
        /// 台数（= 泳道数）。
        var hosts: Int = 8
        /// 每台每秒追加的输出行数。
        var linesPerSecond: Double = 50
        /// 总时长。
        var duration: Duration = .seconds(10)
        /// 失败台数（前 `failingHosts` 台以非 0 退出码收尾）。
        var failingHosts: Int = 0
        /// 连不上的台数（**从末尾数**，与 `failingHosts` 不重叠）：会话 `run` 直接抛错，
        /// 走控制器的 `markUnreachable`。只在「执行器」用法下生效。
        var unreachableHosts: Int = 0
        /// 吐行的节拍（每多少毫秒结算一次「这会儿该吐几行了」）。20ms ≈ 60Hz 一帧多一点。
        var tickMS: Int = 20
        /// 广播的命令文本（每条泳道第一行是它，`PLine.Kind.cmd`）。
        var command: String = "systemctl restart app && journalctl -u app --since -1min | tail -40"
        /// 确定性随机种子（行内容里的耗时 / 数字靠它）。
        var seedValue: UInt64 = 0x9A11_E15E

        init(hosts: Int = 8, linesPerSecond: Double = 50,
             duration: Duration = .seconds(10), failingHosts: Int = 0,
             command: String = "systemctl restart app && journalctl -u app --since -1min | tail -40",
             seedValue: UInt64 = 0x9A11_E15E,
             unreachableHosts: Int = 0, tickMS: Int = 20) {
            self.hosts = hosts
            self.linesPerSecond = linesPerSecond
            self.duration = duration
            self.failingHosts = failingHosts
            self.command = command
            self.seedValue = seedValue
            self.unreachableHosts = unreachableHosts
            self.tickMS = tickMS
        }

        /// 探针档：`hosts` 台在 `seconds` 秒内各流完 `lines` 行（速率 = lines / seconds）。
        /// 与桌面 `ParallelRunScrollCostTests` 同口径：**不预置历史**，从空开始流。
        static func streaming(hosts: Int, lines: Int, seconds: Double = 10,
                              failing: Int = 0, unreachable: Int = 0) -> Config {
            Config(hosts: hosts, linesPerSecond: Double(lines) / seconds,
                   duration: .milliseconds(Int(seconds * 1000)), failingHosts: failing,
                   unreachableHosts: unreachable)
        }

        /// 任务给的默认档：n 台 × 50 行/秒 × 10 秒。
        static func standard(hosts: Int, failing: Int = 0) -> Config {
            Config(hosts: hosts, linesPerSecond: 50, duration: .seconds(10), failingHosts: failing)
        }

        /// 每条泳道最终应有的**输出**行数（不含首行 cmd 与末行结论）。
        var outputLinesPerHost: Int {
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return max(0, Int((seconds * linesPerSecond).rounded()))
        }

        /// 每条泳道最终应有的**总**行数：1 行命令 + N 行输出 + 1 行收尾。
        var totalLinesPerHost: Int { outputLinesPerHost + 2 }
    }

    let config: Config
    /// 与 `ParallelRunController.states` 同形的泳道状态。
    private(set) var states: [PServerState]
    private(set) var startedAt = Date()
    private(set) var finishedAt: Date?

    private var rng: SplitMix64
    private var emitted = 0
    private var pump: Task<Void, Never>?
    /// 当执行器用时已经发出去几条会话（`makeSession` 对不上 id 时按这个发号）。
    fileprivate var handedOutSessions = 0

    /// 用真主机造泳道（`ServerProfile` 来自 `MobileFixtures`）。
    convenience init(config: Config, targets: [ServerProfile]) {
        self.init(config: config, lanes: targets.map {
            (id: $0.id, name: $0.name,
             endpoint: "\($0.username)@\($0.host):\($0.port)",
             display: "\($0.username)@\($0.host)")
        })
    }

    /// 不落库、纯合成泳道（只量泳道成本时用，省一次播种）。
    convenience init(config: Config) {
        self.init(config: config, lanes: (0..<config.hosts).map { i in
            (id: UUID(), name: "node-\(String(format: "%03d", i))",
             endpoint: "root@10.0.\(i / 250).\(i % 250):22",
             display: "root@10.0.\(i / 250).\(i % 250)")
        })
    }

    private init(config: Config,
                 lanes: [(id: UUID, name: String, endpoint: String, display: String)]) {
        self.config = config
        self.rng = SplitMix64(seed: config.seedValue)
        let used = Array(lanes.prefix(config.hosts))
        self.states = used.map {
            PServerState(id: $0.id, name: $0.name,
                         endpoint: $0.endpoint, endpointDisplay: $0.display)
        }
        // 首行是命令，与 `ParallelRunController.runLane` 第一步一致。
        for i in states.indices {
            states[i].lines = [PLine(kind: .cmd, text: config.command)]
        }
    }

    // MARK: - 聚合（与 ParallelRunController 同名同义）

    var total: Int { states.count }
    var okCount: Int { states.filter { $0.tone == .ok }.count }
    var failedCount: Int { states.filter { $0.tone == .failed }.count }
    var allDone: Bool { finishedAt != nil }
    /// 全部泳道的行数合计（含首行 cmd 与收尾行）。
    var totalLines: Int { states.reduce(0) { $0 + $1.lines.count } }

    // MARK: - 同步驱动（行数精确）

    /// 一次性把整段输出发完并收尾。返回总行数。
    @discardableResult
    func emitAll() -> Int {
        startedAt = Date()
        let target = config.outputLinesPerHost
        while emitted < target { emitTick(count: 1) }
        finish()
        return totalLines
    }

    /// 只推进 `count` 行（每台各 `count` 行）。给「输出长到一半时挂载有多贵」用。
    func emit(lines count: Int) {
        let target = min(config.outputLinesPerHost, emitted + count)
        while emitted < target { emitTick(count: 1) }
    }

    // MARK: - 真实节拍驱动

    /// 按 `linesPerSecond` 真实追加输出，跑满 `duration` 后自动收尾。
    /// 每 20ms 一批（一批 `linesPerSecond / 50` 行）—— 与 60Hz 的一帧同量级，
    /// 比「每行一个 timer」少几十倍的调度开销，观感一致。
    ///
    /// 用 `Task { @MainActor in }` 而不是 `Timer`：`Timer` 的 block 是
    /// `@Sendable`，里头再 `weak self` 引一个 `@MainActor` 类，Swift 6
    /// 直接判数据竞争；MainActor 隔离的 Task 没这个问题。
    func start() {
        guard pump == nil, !allDone else { return }
        startedAt = Date()
        let batch = max(1, Int((config.linesPerSecond / 50).rounded()))
        pump = Task { @MainActor [self] in
            while emitted < config.outputLinesPerHost {
                if Task.isCancelled { return }
                emitTick(count: batch)
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled else { return }
            finish()
            pump = nil
        }
    }

    /// 提前停：不收尾，泳道停在 `.running`（复现「用户中途返回」）。
    func stop() {
        pump?.cancel()
        pump = nil
    }

    // MARK: - 内部

    private func emitTick(count: Int) {
        for _ in 0..<count {
            guard emitted < config.outputLinesPerHost else { return }
            let n = emitted
            for i in states.indices {
                let failing = i < config.failingHosts
                states[i].lines.append(PLine(kind: Self.kind(line: n, failing: failing),
                                             text: Self.outputLine(host: i, line: n)))
            }
            emitted += 1
        }
    }

    private func finish() {
        for i in states.indices {
            let failing = i < config.failingHosts
            let code = failing ? [1, 2, 127, 137][i % 4] : 0
            states[i].exitCode = code
            states[i].status = failing ? .failed : .succeeded
            states[i].tone = failing ? .failed : .ok
            states[i].durationMs = Int.random(in: 400...12_000, using: &rng)
            states[i].summary = failing
                ? "命令以退出码 \(code) 结束，执行失败。"
                : "命令执行完成，退出码 0。"
            states[i].lines.append(PLine(kind: failing ? .err : .ok,
                                         text: failing ? "退出码 \(code)" : "完成，退出码 0"))
        }
        finishedAt = Date()
    }

    /// 失败台的输出里混 err 行，成功台是 out/ok —— 四种 `PLine.Kind`
    /// 在一次运行里都要出现，着色分支才走得全。
    nonisolated static func kind(line n: Int, failing: Bool) -> PLine.Kind {
        failing && n % 7 == 3 ? .err : (n % 11 == 5 ? .ok : .out)
    }

    /// 一行输出。长短混合 + 少量 ANSI 风格的宽字符，逼出真实的排版成本。
    nonisolated static func outputLine(host: Int, line: Int) -> String {
        switch line % 6 {
        case 0: return "[\(String(format: "%05d", line))] node-\(host) app.service: active (running)"
        case 1: return "ok"
        case 2: return "Sep 08 10:\(String(format: "%02d", line % 60)):\(String(format: "%02d", (line * 7) % 60)) "
                    + "node-\(host) app[\(1000 + line)]: 处理请求 /api/v1/orders/\(line) 耗时 \(line % 900)ms，"
                    + "上游 upstream-\(host % 5) 返回 200，这一行刻意写长以逼出横向截断"
        case 3: return "  at com.example.service.OrderHandler.handle(OrderHandler.java:\(120 + line % 400))"
        case 4: return "warn: 连接池水位 \(60 + line % 40)% (max=\(4096))"
        default: return "GET /healthz 200 \(line % 50)ms"
        }
    }
}

// MARK: - 当执行器用（挂整屏）

extension MobileFakeParallelRun: ParallelCommandExecuting {

    /// 按主机开一条假会话。
    ///
    /// 泳道序号优先按 `profile.id` 对上自己的 `states`（用 `targets:` 造的实例走这条），
    /// 对不上就按调用顺序发号 —— 控制器起任务的顺序就是 `targets` 的顺序。
    func makeSession(for profile: ServerProfile, approving pin: HostKeyApprovalPin?) -> ParallelExecutionSession {
        let index = states.firstIndex { $0.id == profile.id } ?? handedOutSessions
        handedOutSessions += 1
        let unreachable = index >= config.hosts - config.unreachableHosts
        let failing = index < config.failingHosts
        return MobileFakeParallelSession(
            host: index,
            totalLines: config.outputLinesPerHost,
            linesPerSecond: config.linesPerSecond,
            tickMS: config.tickMS,
            exitCode: failing ? [1, 2, 127, 137][index % 4] : 0,
            failing: failing,
            connectionFailure: unreachable ? "Connection refused (假执行器：第 \(index) 台配成连不上)" : nil)
    }
}

/// 一台主机的假会话：按节拍把行吐给控制器，跑满行数后按配置的退出码收尾。
///
/// 与真实 `SSHParallelSession` 的唯一差别就是 `onLines` —— 真实 SSH 只能在命令结束后
/// 一次性给完整输出，这里按 `linesPerSecond` 逐批吐，于是「输出一直在长」的那几秒
/// 真的在探针里发生（这正是要量的那一段）。
nonisolated struct MobileFakeParallelSession: ParallelExecutionSession {
    let host: Int
    let totalLines: Int
    let linesPerSecond: Double
    let tickMS: Int
    let exitCode: Int
    let failing: Bool
    /// 非 nil = 这台压根连不上（`run` 抛错，控制器走 `markUnreachable`）。
    let connectionFailure: String?

    var setupErrorText: String? { nil }

    func run(_ command: String,
             onLines: @escaping @Sendable ([PLine]) -> Void) async throws -> CommandResult {
        if let connectionFailure { throw MobileFakeParallelFailure(text: connectionFailure) }

        // 按经过时间结算「这会儿该吐到第几行」，而不是每拍固定几行 ——
        // 速率不是整数时（1200 行 / 10 秒 = 120 行/秒、每 20ms 2.4 行）这样才不漂。
        let started = Date()
        var emitted = 0
        while emitted < totalLines {
            try await Task.sleep(for: .milliseconds(tickMS))   // 取消在这里抛
            let want = min(totalLines, Int(Date().timeIntervalSince(started) * linesPerSecond))
            guard want > emitted else { continue }
            onLines((emitted..<want).map { n in
                PLine(kind: MobileFakeParallelRun.kind(line: n, failing: failing),
                      text: MobileFakeParallelRun.outputLine(host: host, line: n))
            })
            emitted = want
        }
        // 收尾行：与 `MobileFakeParallelRun.finish()` 逐字一致。
        onLines([PLine(kind: failing ? .err : .ok,
                       text: failing ? "退出码 \(exitCode)" : "完成，退出码 0")])
        // 行已经吐过了，`output` 只供 AI 提示词与「有没有结果」判定用。
        return CommandResult(output: "（\(totalLines) 行输出已按节拍回吐）", exitCode: exitCode)
    }

    func takeHostKeyChallenge() -> HostKeyChallenge? { nil }

    func close() async {}
}

/// 假会话的连接失败。`localizedDescription` 要如实带出文本 —— 控制器把它摆进
/// 「连接失败：…」那行，探针据此确认失败路径真的走到了。
nonisolated struct MobileFakeParallelFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
