import Foundation

/// Claude Code 自己缓存的 `/usage` 结果：`~/.claude.json` 的 `cachedUsageUtilization`（Claude Code 启动、开 `/usage`、
/// 用着的时候会去取，带取到的时间 `fetchedAtMs`）。比状态栏给的全：状态栏只有 `five_hour` / `seven_day`（过了重置时间
/// 就不给了），这里还有只管某个模型的每周额度（`weekly_scoped`，如 Fable）。账号额度优先读它，状态栏比它新时同一个
/// 时间窗用状态栏的（`AgentStatusLineSnapshot.merging`）。
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
    /// 账号额度合在一起：以 Claude Code 缓存的 `/usage`（时间窗全）为底，状态栏比它新的那几个时间窗换成状态栏的。
    func merging(usageCache: (limits: AgentRateLimits, at: Date?)?) -> AgentStatusLineSnapshot {
        guard let usageCache else { return self }
        var merged = self
        let statusNewer = (at ?? .distantPast) > (usageCache.at ?? .distantPast)
        var windows = usageCache.limits.windows
        if statusNewer, let own = rateLimits?.windows {
            for window in own {
                if let index = windows.firstIndex(where: { $0.windowMinutes == window.windowMinutes && $0.scope == window.scope
                    && $0.label == window.label }) {
                    windows[index] = window
                } else {
                    windows.append(window)
                }
            }
        }
        merged.rateLimits = AgentRateLimits(primary: nil, secondary: nil, plan: rateLimits?.plan, extra: windows)
        merged.at = max(at ?? .distantPast, usageCache.at ?? .distantPast)
        return merged
    }
}
