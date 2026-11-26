import Foundation
import Synchronization

/// 状态栏转接（两端共用）：Claude Code 与 Antigravity 的记录里没有账号额度、也不写上下文窗口多大，只有交给状态栏命令的
/// 那份 JSON 里有（Claude：`rate_limits.five_hour` / `seven_day`、`context_window.context_window_size`；Antigravity：
/// `quota` 的各个 bucket、`context_window`）。我们自己起的 `claude` / `agy` 多带一个 `--settings <文件>`，只在这一次启动里
/// 把状态栏换成主机上的一个小脚本：它把收到的 JSON 存一份，再原样交给你自己配的状态栏命令（没配就什么都不输出，不凭空多一行）。
/// 不改你的 settings.json。
///
/// 主机上的文件都在 `~/.local/share/uterm/statusline/`：
/// - `statusline.sh`：转接脚本（每次连上都按 App 里的这一份重写，改了脚本不会留着旧的）；
/// - `<工具>.settings.json`：传给 `--settings` 的那一份；
/// - `<工具>.original`：你原来配的状态栏命令（连上时从你的 settings.json 里读出来）；没配就没有这个文件；
/// - `<工具>.last.json`：最近一次状态栏的数据，App 读它。
nonisolated enum AgentStatusLineBridge {
    static let relativeDirectory = ".local/share/uterm/statusline"

    /// 转接的是哪种工具，以及它的用户设置在哪。
    enum Tool: String, Sendable {
        case claude
        case antigravity

        var userSettings: String {
            switch self {
            case .claude: return ".claude/settings.json"
            case .antigravity: return ".gemini/antigravity-cli/settings.json"
            }
        }
    }

    static func directory(home: String) -> String { home + "/" + relativeDirectory }
    static func scriptPath(home: String) -> String { directory(home: home) + "/statusline.sh" }
    static func settingsPath(_ tool: Tool, home: String) -> String { directory(home: home) + "/\(tool.rawValue).settings.json" }
    static func originalPath(_ tool: Tool, home: String) -> String { directory(home: home) + "/\(tool.rawValue).original" }
    static func snapshotPath(_ tool: Tool, home: String) -> String { directory(home: home) + "/\(tool.rawValue).last.json" }

    /// 转接脚本。存一份用临时文件 + 改名，App 读到的不会是写了一半的。
    static let script = """
    #!/bin/sh
    # uTerm 的状态栏转接（只在 uTerm 起的 claude / agy 里用，见 --settings）：把状态栏收到的数据存一份给 uTerm 读
    # （账号额度、上下文窗口），再原样交给你自己配的状态栏命令；没配就什么都不显示。你的状态栏照旧在 settings.json 里改，
    # uTerm 每次连上这台主机时重新读一遍。
    dir=$(dirname "$0")
    tool=$1
    input=$(cat)
    tmp="$dir/$tool.last.json.$$"
    printf '%s\\n' "$input" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$tool.last.json" 2>/dev/null
    if [ -s "$dir/$tool.original" ]; then
      printf '%s\\n' "$input" | sh -c "$(cat "$dir/$tool.original")"
    fi

    """

    /// POSIX shell 的单引号。
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 装好（或刷新）这种工具的转接，返回要传给 `--settings` 的文件。读你的 settings.json 失败（没有这个文件）当作没配状态栏。
    static func install(_ tool: Tool, provider: any SFTPProviding, home: String) async throws -> String {
        let user = (try? await provider.download(remotePath: home + "/" + tool.userSettings, maximumBytes: 1 << 20))
            .flatMap(UserStatusLine.init(settings:))
        let directory = directory(home: home)
        try await createDirectories(directory, provider: provider)
        try await writeIfChanged(scriptPath(home: home), Data(script.utf8), provider: provider)
        let settings = settingsJSON(tool, scriptPath: scriptPath(home: home), user: user)
        try await writeIfChanged(settingsPath(tool, home: home), settings, provider: provider)
        if let command = user?.command {
            try await writeIfChanged(originalPath(tool, home: home), Data(command.utf8), provider: provider)
        } else {
            try? await provider.removeFile(originalPath(tool, home: home))
        }
        return settingsPath(tool, home: home)
    }

    /// 传给 `--settings` 的 JSON：状态栏换成转接脚本。Claude 照抄你的 `padding`；Antigravity 没配自己的状态栏时叠在自带的
    /// 那一行下面（`stack_with_default`，脚本什么都不输出，看到的还是自带的），配了就照你的。
    static func settingsJSON(_ tool: Tool, scriptPath: String, user: UserStatusLine?) -> Data {
        var line: [String: Any] = ["type": "command", "command": "sh \(quoted(scriptPath)) \(tool.rawValue)"]
        if let padding = user?.padding { line["padding"] = padding }
        if tool == .antigravity { line["stack_with_default"] = user?.command == nil ? true : (user?.stacksWithDefault ?? false) }
        return (try? JSONSerialization.data(withJSONObject: ["statusLine": line], options: [.sortedKeys])) ?? Data()
    }

    /// 你在 settings.json 里配的状态栏。
    struct UserStatusLine: Equatable, Sendable {
        var command: String?
        var padding: Int?
        var stacksWithDefault: Bool?

        init?(settings data: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let line = object["statusLine"] as? [String: Any] else { return nil }
            let command = (line["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // 关掉了自定义状态栏（Antigravity 的 `enabled: false`）：当作没配。
            self.command = (line["enabled"] as? Bool == false || command?.isEmpty != false) ? nil : command
            padding = (line["padding"] as? NSNumber)?.intValue
            stacksWithDefault = line["stack_with_default"] as? Bool
        }
    }

    /// 读最近一次状态栏的数据；没有（还没起过、没装上）为 nil。
    static func readSnapshot(_ tool: Tool, provider: any SFTPProviding, home: String) async -> AgentStatusLineSnapshot? {
        let path = snapshotPath(tool, home: home)
        guard let stat = try? await provider.stat(path),
              let data = try? await provider.download(remotePath: path, maximumBytes: 1 << 20) else { return nil }
        return AgentStatusLineSnapshot.parse(data, at: stat.mtime)
    }

    private static func createDirectories(_ directory: String, provider: any SFTPProviding) async throws {
        if (try? await provider.stat(directory)) != nil { return }
        var path = ""
        for component in directory.split(separator: "/") {
            path += "/" + component
            if (try? await provider.stat(path)) == nil { try await provider.createDirectory(path) }
        }
    }

    private static func writeIfChanged(_ path: String, _ data: Data, provider: any SFTPProviding) async throws {
        if let existing = try? await provider.download(remotePath: path, maximumBytes: 1 << 20), existing == data { return }
        try await provider.write(path, data: data)
    }
}

/// 状态栏数据里我们要的几样。
nonisolated struct AgentStatusLineSnapshot: Equatable, Sendable {
    var sessionID: String?
    /// 上下文窗口多大（Claude 的状态栏才有）。
    var contextWindow: Int?
    var rateLimits: AgentRateLimits?
    /// 这份数据是几时写的（文件的修改时间）。
    var at: Date?

    /// Claude Code：`rate_limits.five_hour` / `seven_day` 的 `used_percentage`（0–100）与 `resets_at`（秒）。
    /// Antigravity：`quota` 里每个 bucket 的 `remaining_fraction`（0–1，或只给 `remaining_amount`，那就不知道用了几成，不显示）
    /// 与 `reset_time`（ISO 8601）；bucket 名就是时间窗的名字。两边的 `context_window.context_window_size`（0 是不知道）。
    static func parse(_ data: Data, at: Date?) -> AgentStatusLineSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let session = (object["session_id"] as? String) ?? (object["conversation_id"] as? String)
        let window = ((object["context_window"] as? [String: Any])?["context_window_size"] as? NSNumber)?.intValue
        var windows: [AgentRateLimits.Window] = []
        if let limits = object["rate_limits"] as? [String: Any] {
            // 有哪几个就列哪几个：有的账号没有 5 小时的，有的另有只管某个模型的每周额度（`seven_day_fable` 之类）。
            for key in limits.keys.sorted() {
                guard let entry = limits[key] as? [String: Any],
                      let used = (entry["used_percentage"] as? NSNumber)?.doubleValue else { continue }
                let resets = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(claudeWindow(key: key, used: used, resetsAt: resets))
            }
        }
        if let quota = object["quota"] as? [String: Any] {
            for key in quota.keys.sorted() {
                guard let entry = quota[key] as? [String: Any], entry["disabled"] as? Bool != true,
                      let remaining = (entry["remaining_fraction"] as? NSNumber)?.doubleValue else { continue }
                let resets = (entry["reset_time"] as? String).flatMap(ClaudeTimestamp.parse)
                windows.append(AgentRateLimits.Window(usedPercent: max(0, min(100, (1 - remaining) * 100)),
                                                      windowMinutes: nil, resetsAt: resets, label: key))
            }
        }
        let limits = AgentRateLimits(primary: nil, secondary: nil, plan: object["plan_tier"] as? String, extra: windows)
        return AgentStatusLineSnapshot(sessionID: session?.lowercased(), contextWindow: window.flatMap { $0 > 0 ? $0 : nil },
                                       rateLimits: limits.windows.isEmpty ? nil : limits, at: at)
    }
}

nonisolated extension AgentStatusLineSnapshot {
    /// Claude 状态栏里 `rate_limits` 的一项：`five_hour` / `seven_day` 是全部模型合计的，后面再跟模型名的
    /// （`seven_day_fable`、`seven_day_opus`）只管那个模型。认不出前缀的照原样当名字。
    static func claudeWindow(key: String, used: Double, resetsAt: Date?) -> AgentRateLimits.Window {
        for (prefix, minutes) in [("five_hour", 300), ("seven_day", 7 * 24 * 60)] where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count).drop { $0 == "_" }
            let scope = rest.isEmpty ? nil : rest.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return AgentRateLimits.Window(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt, scope: scope)
        }
        return AgentRateLimits.Window(usedPercent: used, windowMinutes: nil, resetsAt: resetsAt, label: key)
    }
}

/// 侧栏底部一种工具的账号额度（`AgentHistoryModel.accountLimits`）。`windows` 最紧的在前（`tightestFirst`），
/// 过了重置时间的按用了 0 算（`didReset`）。
nonisolated struct AgentAccountLimits: Equatable, Sendable {
    var tool: AgentHistoryTool
    var limits: AgentRateLimits
    var windows: [AgentRateLimits.Window]
    var at: Date?

    /// 窄的地方只显示一个：最接近 100% 的那个时间窗（`windows` 已按最紧的在前排好）。
    var headline: AgentRateLimits.Window? { windows.first }
}

/// 数据源里记着转接装没装好：拼命令（`resumeCommand` / `newSessionCommand`，nonisolated）时才知道带不带 `--settings`。
nonisolated final class AgentStatusLineState: Sendable {
    private let settings = Mutex<String?>(nil)

    var settingsPath: String? { settings.withLock { $0 } }

    func installed(at path: String?) { settings.withLock { $0 = path } }
}
