import Foundation

/// Claude Code 自己缓存的 `/usage` 结果：`~/.claude.json` 的 `cachedUsageUtilization`（Claude Code 启动、开 `/usage`、
/// 用着的时候会去取，带取到的时间 `fetchedAtMs`）。是整个账号的、时间窗全（还有只管某个模型的每周额度 `weekly_scoped`，
/// 如 Fable）。有它就只用它（`AgentStatusLineSnapshot.merging`）：状态栏里的额度是那一个会话最后一次 API 回应带的，
/// 文件的修改时间新不代表额度新（实测状态栏 10:18 写的还是「每周 91%、没有 5 小时」，同时 10:15 取的 /usage 是 94%、6%）。
///
/// 只读这一个字段，文件里别的东西不看、不记。
nonisolated enum ClaudeUsageCache {
    static func path(home: String) -> String { home + "/.claude.json" }

    static func read(provider: any SFTPProviding, home: String) async -> (limits: AgentRateLimits, at: Date?)? {
        guard let data = try? await provider.download(remotePath: path(home: home), maximumBytes: 16 << 20) else { return nil }
        return parse(data)
    }

    /// `utilization.limits` 的每一项：`kind` 是 `session`（5 小时）、`weekly_all`（每周，全部模型）、`weekly_scoped`
    /// （每周，只管 `scope.model.display_name` 那个模型）；`percent` 用了几成（0–100），`resets_at` ISO 8601。
    /// 没有 `limits` 的老版本退回 `five_hour` / `seven_day` 的 `utilization`。
    static func parse(_ data: Data) -> (limits: AgentRateLimits, at: Date?)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"] as? [String: Any] else { return nil }
        let at = (cache["fetchedAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        var windows: [AgentRateLimits.Window] = []
        if let limits = utilization["limits"] as? [Any] {
            for case let limit as [String: Any] in limits {
                guard let kind = limit["kind"] as? String,
                      let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
                let resets = (limit["resets_at"] as? String).flatMap(ClaudeTimestamp.parse)
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                switch kind {
                case "session":
                    windows.append(.init(usedPercent: percent, windowMinutes: 300, resetsAt: resets))
                case "weekly_all":
                    windows.append(.init(usedPercent: percent, windowMinutes: 7 * 24 * 60, resetsAt: resets))
                case "weekly_scoped":
                    windows.append(.init(usedPercent: percent, windowMinutes: 7 * 24 * 60, resetsAt: resets,
                                         scope: model ?? "?"))
                default:
                    windows.append(.init(usedPercent: percent, windowMinutes: nil, resetsAt: resets, label: kind,
                                         scope: model))
                }
            }
        } else {
            for (key, minutes) in [("five_hour", 300), ("seven_day", 7 * 24 * 60)] {
                guard let entry = utilization[key] as? [String: Any],
                      let used = (entry["utilization"] as? NSNumber)?.doubleValue else { continue }
                let resets = (entry["resets_at"] as? String).flatMap(ClaudeTimestamp.parse)
                windows.append(.init(usedPercent: used, windowMinutes: minutes, resetsAt: resets))
            }
        }
        guard !windows.isEmpty else { return nil }
        return (AgentRateLimits(primary: nil, secondary: nil, plan: nil, extra: windows), at)
    }
}

nonisolated extension AgentStatusLineSnapshot {
    /// 账号额度：有 Claude Code 缓存的 `/usage` 就只用它（时间也用它取到的时间）；没有才用状态栏的。上下文窗口照旧是状态栏的。
    func merging(usageCache: (limits: AgentRateLimits, at: Date?)?) -> AgentStatusLineSnapshot {
        guard let usageCache else { return self }
        var merged = self
        merged.rateLimits = usageCache.limits
        merged.at = usageCache.at
        return merged
    }
}
