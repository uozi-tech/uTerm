import Foundation
import Observation

/// 网络诊断页的状态：对一台 Mac 跑一次链路矩阵、进度、本次 / 上次结果、历史条数。两端的诊断页都只画它。
///
/// 每条结果一出来就记进 `log`（中途停止，已测完的也留着）。测哪些路、跑几轮、备注由页面传进来——那几项是
/// `@AppStorage` 偏好，跟着页面走。
@MainActor
@Observable
final class RemotePathDiagnosticsModel {
    let log: RemotePathMatrixLog
    /// 正在测（或刚测完）的这一次。
    private(set) var current: [RemotePathProbeResult] = []
    private(set) var currentTotal = 0
    /// 这一次要测的路，按顺序；进度文案要用。
    private(set) var plannedModes: [RemotePathProbeMode] = []
    private(set) var lastRun: [RemotePathProbeResult] = []
    private(set) var historyCount = 0
    private(set) var network = "…"
    private(set) var isRunning = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let networkLabel: @Sendable () async -> String

    init(log: RemotePathMatrixLog,
         networkLabel: @escaping @Sendable () async -> String = { await RemoteNetworkLabel.current() }) {
        self.log = log
        self.networkLabel = networkLabel
    }

    /// 正在测或刚测完的这一次；没有就上一次。
    var shown: [RemotePathProbeResult] {
        current.isEmpty ? lastRun : current
    }

    var summaries: [RemotePathProbeSummary] {
        RemotePathProbeSummary.summarize(shown)
    }

    /// 这一组结果里没测到的路：结论只对测过的路负责。
    var untested: [RemotePathProbeMode] {
        let tested = Set(shown.map(\.mode))
        return RemotePathProbeMode.allCases.filter { !tested.contains($0) }
    }

    var progressText: String {
        guard current.count < currentTotal, !plannedModes.isEmpty else { return "收尾中…" }
        let index = current.count
        let rounds = currentTotal / plannedModes.count
        let round = rounds > 1 ? "第 \(index / plannedModes.count + 1) 轮 · " : ""
        return "\(round)正在测试\(plannedModes[index % plannedModes.count].label)（\(index + 1)/\(currentTotal)）"
    }

    func reloadHistory() {
        historyCount = log.load().count
        lastRun = log.lastRun()
    }

    func refreshNetwork() async {
        network = await networkLabel()
    }

    func run(runner: RemotePathMatrixRunner, peer: RemotePeer, rounds: Int, modes: [RemotePathProbeMode],
             note: String) {
        guard !isRunning, !modes.isEmpty else { return }
        let rounds = max(1, rounds)
        current = []
        currentTotal = rounds * modes.count
        plannedModes = modes
        isRunning = true
        task = Task { [weak self, networkLabel] in
            let network = await networkLabel()
            self?.network = network
            _ = await runner.run(mac: peer, rounds: rounds, modes: modes) { [weak self] finished in
                var result = finished
                result.note = note
                result.network = network
                await self?.received(result)
            }
            self?.finished()
        }
    }

    func stop() {
        task?.cancel()
    }

    /// 等这一次跑完（或停下）。测试用。
    func waitUntilFinished() async {
        await task?.value
    }

    func clearHistory() {
        log.clear()
        current = []
        reloadHistory()
    }

    private func received(_ result: RemotePathProbeResult) {
        current.append(result)
        log.append([result])
    }

    private func finished() {
        task = nil
        isRunning = false
        reloadHistory()
    }
}
