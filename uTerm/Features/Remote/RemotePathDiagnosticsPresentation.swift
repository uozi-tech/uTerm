import Foundation

/// 网络诊断页上要显示的文字与状态（两端的诊断页只画，不各写一份）。

extension RemotePathProbeMode {
    /// 要测的路。偏好里存的是**跳过的**（逗号分隔）：以后加了新路，默认就会测。
    nonisolated static func enabled(skipping skippedRaw: String) -> [RemotePathProbeMode] {
        let skipped = Set(skippedRaw.split(separator: ",").map(String.init))
        return allCases.filter { !skipped.contains($0.rawValue) }
    }

    /// 打开 / 关掉一条路之后，偏好里该存的「跳过的路」。
    nonisolated static func skippedRaw(_ skippedRaw: String, setting mode: RemotePathProbeMode, enabled on: Bool) -> String {
        var enabled = Set(Self.enabled(skipping: skippedRaw))
        if on { enabled.insert(mode) } else { enabled.remove(mode) }
        return allCases.filter { !enabled.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

extension RemotePathProbeSummary {
    /// 通过率着色：全通、部分通、全不通。颜色由各端的色板定。
    nonisolated enum Tone: Equatable, Sendable {
        case passed, partial, failed
    }

    nonisolated var tone: Tone {
        if successes == attempts { return .passed }
        return successes == 0 ? .failed : .partial
    }
}

extension RemotePathVerdict {
    /// 结论的标题：「实际会走中继」；都不通时说清是「这台 Mac 现在连不上」还是「测过的路都不通」。
    nonisolated static func title(chosen: RemotePathProbeSummary?, untested: [RemotePathProbeMode]) -> String {
        guard let chosen else {
            return untested.isEmpty ? String(localized: "现在无法连接这台 Mac") : String(localized: "测试过的路径都不通")
        }
        return String(localized: "实际会走\(chosen.mode.label)")
    }

    /// 结论的说明：往返多少、「只走公网」的影响、这次没测哪几条。
    nonisolated static func detail(chosen: RemotePathProbeSummary?, untested: [RemotePathProbeMode],
                                   skipsLocalNetwork: Bool) -> String {
        let notTested = untested.isEmpty ? ""
            : String(localized: "这次未测试\(untested.map(\.label).joined(separator: String(localized: "、", comment: "并列项之间的分隔符")))（在「检测设置」中打开）。")
        guard let chosen else { return String(localized: "各路径的失败原因见下方。\(notTested)") }
        let latency = chosen.medianRoundTripMillis.map { String(localized: "往返约 \(Int($0.rounded())) ms") }
            ?? String(localized: "往返未测出")
        let skip = skipsLocalNetwork ? String(localized: "「只走公网」已打开，正式连接会跳过局域网。") : ""
        return String(localized: "连接按局域网 → 直连 → 中继的顺序选第一条可用的路径，\(latency)。\(skip)\(notTested)")
    }
}

extension RemotePathMatrixLog {
    /// 一次检测的网络与备注（脚注用；区段标题会转大写，「Wi-Fi」会变成「WI-FI」）。都没有时 nil。
    nonisolated static func context(_ run: [RemotePathProbeResult]) -> String? {
        let parts = [run.first?.network ?? "", run.first?.note ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 「拷贝全部」：全部记录，按时间先后。
    func exportAllText() -> String {
        Self.exportText(load().reversed())
    }
}

extension RemotePathDiagnosticsModel {
    /// 结果区的标题：正在测、刚测完，还是上次的结果（带时间）。
    var resultsTitle: String {
        if isRunning { return String(localized: "正在检测") }
        guard current.isEmpty else { return String(localized: "检测结果") }
        let date = shown.first?.date.formatted(date: .abbreviated, time: .shortened) ?? ""
        return String(localized: "上次结果 · \(date)")
    }
}
