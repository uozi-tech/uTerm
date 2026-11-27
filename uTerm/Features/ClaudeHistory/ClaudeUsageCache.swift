import Foundation

/// Claude Code 自己缓存的 `/usage` 结果：`~/.claude.json` 的 `cachedUsageUtilization`（Claude Code 启动、开 `/usage`、
/// 用着的时候会去取，带取到的时间 `fetchedAtMs`）。是整个账号的、时间窗全（还有只管某个模型的每周额度 `weekly_scoped`，
/// 如 Fable）。和状态栏的按时间窗合起来（`AgentStatusLineSnapshot.merging`）：Claude Code 只在启动、开 `/usage` 之类的
/// 时候才去取它，跑着的会话每次 API 回应都会在状态栏里带上新的额度；可状态栏也会旧（文件修改时间新不代表额度新：实测状态栏
/// 10:18 写的是「每周 91%、没有 5 小时」，同时 10:15 取的 /usage 是 94%、6%）。所以不比文件的时间，比额度本身。
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
    /// 账号额度：以 Claude Code 缓存的 `/usage` 为底（时间窗全），状态栏里有的同一个时间窗（窗长、只管的模型都一样）取
    /// 更新的那份（`AgentRateLimits.Window.fresher`）；状态栏没给的时间窗用缓存的，不补 0。上下文窗口照旧是状态栏的。
    ///
    /// 每个时间窗带着它那份读数的时间（`observedAt`），整份的时间（侧栏点开的「截至」）取显示出来的里面最早的：
    /// 数字取了缓存那份、时间却写状态栏那份，就把几个小时前的数说成刚读的（实机：状态栏 19:07 写的还是旧的「每周 91」，
    /// 显示的 96% 是 15:44 的 /usage）。
    func merging(usageCache: (limits: AgentRateLimits, at: Date?)?) -> AgentStatusLineSnapshot {
        guard let usageCache else { return self }
        var windows = usageCache.limits.windows.map { $0.observed(at: usageCache.at) }
        for window in (rateLimits?.windows ?? []).map({ $0.observed(at: at) }) {
            if let index = windows.firstIndex(where: { $0.isSameWindow(as: window) }) {
                windows[index] = .fresher(windows[index], window)
            } else {
                windows.append(window)
            }
        }
        var merged = self
        merged.rateLimits = AgentRateLimits(primary: nil, secondary: nil, plan: rateLimits?.plan, extra: windows)
        merged.at = windows.compactMap(\.observedAt).min() ?? max(at ?? .distantPast, usageCache.at ?? .distantPast)
        return merged
    }
}

nonisolated extension AgentRateLimits.Window {
    /// 带上读数的时间（已经带着的不改）。
    func observed(at time: Date?) -> Self {
        var window = self
        if window.observedAt == nil { window.observedAt = time }
        return window
    }

    /// 同一个时间窗：窗长、名字、只管的模型都一样。
    func isSameWindow(as other: Self) -> Bool {
        windowMinutes == other.windowMinutes && label == other.label && scope == other.scope
    }

    /// 两份读数取更新的：重置时间差一分钟以上的是两个周期，取后一个周期的；同一个周期里用量只增不减，取用得多的。
    static func fresher(_ a: Self, _ b: Self) -> Self {
        if let left = a.resetsAt, let right = b.resetsAt, abs(left.timeIntervalSince(right)) > 60 {
            return left > right ? a : b
        }
        return b.usedPercent > a.usedPercent ? b : a
    }
}
