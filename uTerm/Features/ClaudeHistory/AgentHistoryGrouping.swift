import Foundation

/// 会话列表怎么分组。原始值存在偏好设置里（`DefaultsKey.agentHistoryGrouping`），**已有的不改**。
nonisolated enum AgentHistoryGrouping: String, CaseIterable, Sendable, Identifiable {
    /// 按工作目录（几种工具的会话在同一个目录下的并成一组）。
    case project
    /// 今天 / 昨天 / 过去 7 天 / 过去 30 天 / 更早。
    case date
    case tool
    case none

    static let `default`: AgentHistoryGrouping = .project

    var id: String { rawValue }
}

/// 按日期分组的那几档，先近后远。
nonisolated enum AgentHistoryDateBucket: Int, CaseIterable, Sendable {
    case today, yesterday, pastWeek, pastMonth, older

    /// 按日历天数算：今天、昨天、2–6 天前（过去 7 天）、7–29 天前（过去 30 天）、更早。比现在还晚的（时钟不准）算今天。
    static func bucket(for date: Date, now: Date, calendar: Calendar) -> AgentHistoryDateBucket {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case 2...6: return .pastWeek
        case 7...29: return .pastMonth
        default: return .older
        }
    }
}

/// 列表里的一组。
nonisolated struct AgentHistoryGroup: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        /// `directory`：工作目录（悬停显示）；对不上真实目录的（Claude Code 的目录名换不回路径）为 nil，
        /// 这时 `name` 是记录目录的名字。
        /// `name` 是组标题：目录最后一段，有同名的目录时往上多带一段（`a/api`、`b/api`）。
        case project(directory: String?, name: String)
        /// 这种工具没有记下工作目录的会话（Antigravity 没开文件夹的会话、Cursor 对不上目录的）：一种工具一组。
        case noDirectory(AgentHistoryTool)
        case date(AgentHistoryDateBucket)
        case tool(AgentHistoryTool)
        /// 不分组：只有一组（前面没有「置顶」一组时不画组标题，见 `AgentHistoryListing.showsHeader`）。
        case all
        /// 用户置顶的会话（`AgentHistoryPins`）：总在最上面，组里按用户排的顺序。
        case pinned
    }

    /// 在同一种分组方式里唯一且稳定（折叠状态按它记）。
    let id: String
    let kind: Kind
    var files: [AgentHistorySessionFile]

    /// 「置顶」一组的 ID。
    static let pinnedID = "pinned"

    /// 组里不止一种工具：行上要写出是哪种（行前不画工具标记，写在第二行小字的最前面）。
    var mixesTools: Bool { AgentHistoryListing.mixesTools(files) }
}

/// 分组、筛选、定位的纯函数。两端共用，界面只画。
nonisolated enum AgentHistoryListing {
    /// 把（已经按时间新的在前排好的）会话分组。组按其中最新那个会话的先后排；日期、工具按固定的先后。
    /// `date`：这一行用哪个时间（列表上显示的那个，看过的会话可能比修改时间新）。
    /// `pinned`：置顶的会话（已按用户排的顺序，见 `AgentHistoryPinning.resolved`）：放在最上面一组「置顶」，
    /// 不再出现在原来那一组里（原组的个数跟着少，少到 0 的组不出）。
    static func groups(_ files: [AgentHistorySessionFile], by grouping: AgentHistoryGrouping,
                       metadata: [String: AgentHistorySessionMetadata],
                       pinned: [AgentHistorySessionFile] = [],
                       date: (AgentHistorySessionFile) -> Date = \.modifiedAt,
                       now: Date = Date(), calendar: Calendar = .current) -> [AgentHistoryGroup] {
        guard !pinned.isEmpty else {
            return unpinnedGroups(files, by: grouping, metadata: metadata, date: date, now: now, calendar: calendar)
        }
        let pinnedPaths = Set(pinned.map(\.path))
        let rest = unpinnedGroups(files.filter { !pinnedPaths.contains($0.path) }, by: grouping, metadata: metadata,
                                  date: date, now: now, calendar: calendar)
        return [AgentHistoryGroup(id: AgentHistoryGroup.pinnedID, kind: .pinned, files: pinned)] + rest
    }

    /// 组标题画不画：只有「不分组」那一组、前面也没有「置顶」时不画。
    static func showsHeader(_ group: AgentHistoryGroup, in groups: [AgentHistoryGroup]) -> Bool {
        group.kind != .all || groups.count > 1
    }

    /// 这些行里不止一种工具。
    static func mixesTools(_ files: [AgentHistorySessionFile]) -> Bool {
        guard let first = files.first?.tool else { return false }
        return files.contains { $0.tool != first }
    }

    private static func unpinnedGroups(_ files: [AgentHistorySessionFile], by grouping: AgentHistoryGrouping,
                                       metadata: [String: AgentHistorySessionMetadata],
                                       date: (AgentHistorySessionFile) -> Date,
                                       now: Date, calendar: Calendar) -> [AgentHistoryGroup] {
        switch grouping {
        case .none:
            return files.isEmpty ? [] : [AgentHistoryGroup(id: "all", kind: .all, files: files)]
        case .tool:
            let byTool = Dictionary(grouping: files, by: \.tool)
            return AgentHistoryTool.allCases.compactMap { tool in
                guard let mine = byTool[tool] else { return nil }
                return AgentHistoryGroup(id: "tool:\(tool.rawValue)", kind: .tool(tool), files: mine)
            }
        case .date:
            let byBucket = Dictionary(grouping: files) {
                AgentHistoryDateBucket.bucket(for: date($0), now: now, calendar: calendar)
            }
            return AgentHistoryDateBucket.allCases.compactMap { bucket in
                guard let mine = byBucket[bucket] else { return nil }
                return AgentHistoryGroup(id: "date:\(bucket.rawValue)", kind: .date(bucket), files: mine)
            }
        case .project:
            return projectGroups(files, metadata: metadata)
        }
    }

    // MARK: 按项目

    /// 一个会话归到哪个项目。
    nonisolated enum ProjectKey: Hashable, Sendable {
        /// 知道真实的工作目录（规整过的绝对路径）。
        case directory(String)
        /// 不知道：某种工具的某个记录目录（Claude Code 的目录名，换不回路径）。
        case unresolved(AgentHistoryTool, String)
    }

    /// 会话的工作目录：数据源放在项目上的真实目录（Codex 等直接有），没有就用会话信息里「该在哪个目录继续」的那个
    /// （Claude Code 由记录里的 `cwd` 对上目录名算出来）。都没有就只知道记录目录的名字。
    static func projectKey(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata?) -> ProjectKey {
        if let directory = file.project.directory ?? metadata?.resumeDirectory,
           let normalized = ClaudeProjectPath.normalized(directory) {
            return .directory(normalized)
        }
        // 只有 Claude Code 的记录目录名看得懂（工作目录换出来的）；别的工具没有目录时那个名字是哈希或占位，
        // 不拿来当标题，一种工具并成一组。
        return .unresolved(file.tool, file.tool == .claude ? file.project.id : "")
    }

    /// 同一个工作目录下几种工具的会话并成一组。
    ///
    /// 难在 Claude Code：它的记录目录名是工作目录换出来的（有损，`/a-b` 与 `/a/b` 是同一个名字），会话信息还没读到、
    /// 或者记录里没有对得上的 `cwd` 时只有这个名字。这时看别的会话里出现过的真实目录，换算出来正好等于这个名字、
    /// 而且只有一个这样的目录，就并进去；对不上或者有歧义的单独成组，标题用目录名。
    static func projectGroups(_ files: [AgentHistorySessionFile],
                              metadata: [String: AgentHistorySessionMetadata]) -> [AgentHistoryGroup] {
        var keys = files.map { projectKey($0, metadata: metadata[$0.path]) }
        let known = Set(keys.compactMap { key -> String? in
            if case .directory(let directory) = key { return directory }
            return nil
        })
        let byEncoded = Dictionary(grouping: known, by: ClaudeProjectPath.encode)
        for index in keys.indices {
            guard case .unresolved(.claude, let name) = keys[index],
                  let matches = byEncoded[name], matches.count == 1, let directory = matches.first else { continue }
            keys[index] = .directory(directory)
        }

        var order: [ProjectKey] = []
        var members: [ProjectKey: [AgentHistorySessionFile]] = [:]
        for (file, key) in zip(files, keys) {
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(file)
        }
        let titles = disambiguatedTitles(order.compactMap { key -> String? in
            if case .directory(let directory) = key { return directory }
            return nil
        })
        return order.map { key in
            let group = members[key] ?? []
            switch key {
            case .directory(let directory):
                let name = titles[directory] ?? (directory as NSString).lastPathComponent
                return AgentHistoryGroup(id: "project:" + directory, kind: .project(directory: directory, name: name),
                                         files: group)
            case .unresolved(let tool, _) where tool != .claude:
                return AgentHistoryGroup(id: "project?\(tool.rawValue)", kind: .noDirectory(tool), files: group)
            case .unresolved(let tool, let name):
                return AgentHistoryGroup(id: "project?\(tool.rawValue):\(name)", kind: .project(directory: nil, name: name),
                                         files: group)
            }
        }
    }

    /// 目录 → 组标题：最后一段；最后一段重名的往上多带一段，直到不重名（或者到头）。
    static func disambiguatedTitles(_ directories: [String]) -> [String: String] {
        func title(_ directory: String, depth: Int) -> String {
            let parts = directory.split(separator: "/")
            guard !parts.isEmpty else { return directory }
            return parts.suffix(depth).joined(separator: "/")
        }
        var result: [String: String] = [:]
        var pending = Set(directories)
        var depth = 1
        while !pending.isEmpty {
            let titled = Dictionary(grouping: pending) { title($0, depth: depth) }
            for (name, members) in titled where members.count == 1 || depth >= 8 {
                for member in members { result[member] = name }
                pending.subtract(members)
            }
            depth += 1
        }
        return result
    }

    /// 终端当前目录落在哪一组：自己或最近的上级目录那一组；Claude Code 没对上真实目录的那种组，按目录名换算对。
    static func groupID(containing directory: String, in groups: [AgentHistoryGroup]) -> String? {
        for candidate in ClaudeProjectPath.lineage(of: directory) {
            let encoded = ClaudeProjectPath.encode(candidate)
            let hit = groups.first { group in
                guard case .project(let known, let name) = group.kind else { return false }
                return known.map { $0 == candidate } ?? (name == encoded)
            }
            if let hit { return hit.id }
        }
        return nil
    }

    // MARK: 只看哪几种工具

    /// 实际生效的筛选：选了的里面这台主机上有的。只有一种工具、什么都没选、或者选的这台上一种都没有，都按全部算。
    static func effectiveTools(shown: Set<AgentHistoryTool>?, available: [AgentHistoryTool]) -> Set<AgentHistoryTool> {
        let all = Set(available)
        guard available.count > 1, let shown else { return all }
        let effective = shown.intersection(all)
        return effective.isEmpty ? all : effective
    }

    /// 在「显示」里点了一种：切换它；全都勾上就回到「全部」（nil），不许一种都不勾。
    static func toggling(_ tool: AgentHistoryTool, shown: Set<AgentHistoryTool>?,
                         available: [AgentHistoryTool]) -> Set<AgentHistoryTool>? {
        var next = effectiveTools(shown: shown, available: available)
        if next.contains(tool) {
            guard next.count > 1 else { return shown }
            next.remove(tool)
        } else {
            next.insert(tool)
        }
        return next == Set(available) ? nil : next
    }
}

/// 列表的偏好：分组方式与「显示」里勾的工具。只存枚举的原始值，不存路径、会话 ID、标题。
nonisolated struct AgentHistoryListPreferences: Equatable, Sendable {
    var grouping: AgentHistoryGrouping = .default
    /// nil = 全部。
    var shownTools: Set<AgentHistoryTool>?

    init(grouping: AgentHistoryGrouping = .default, shownTools: Set<AgentHistoryTool>? = nil) {
        self.grouping = grouping
        self.shownTools = shownTools
    }

    init(defaults: UserDefaults) {
        grouping = Self.decodeGrouping(defaults.string(forKey: DefaultsKey.agentHistoryGrouping))
        shownTools = Self.decodeTools(defaults.string(forKey: DefaultsKey.agentHistoryShownTools) ?? "")
    }

    func save(to defaults: UserDefaults) {
        defaults.set(grouping.rawValue, forKey: DefaultsKey.agentHistoryGrouping)
        defaults.set(Self.encodeTools(shownTools), forKey: DefaultsKey.agentHistoryShownTools)
    }

    /// 「恢复默认」：两个键都删掉。
    static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: DefaultsKey.agentHistoryGrouping)
        defaults.removeObject(forKey: DefaultsKey.agentHistoryShownTools)
    }

    static func decodeGrouping(_ raw: String?) -> AgentHistoryGrouping {
        raw.flatMap(AgentHistoryGrouping.init(rawValue:)) ?? .default
    }

    /// 列表实际用的分组：只有一种工具时没有「工具」这种分组，存的是它就按默认的来。
    static func effectiveGrouping(_ raw: String?, isMultiTool: Bool) -> AgentHistoryGrouping {
        let stored = decodeGrouping(raw)
        return stored == .tool && !isMultiTool ? .default : stored
    }

    /// 菜单里能选的分组方式（只有一种工具时不出「工具」）。
    static func groupingChoices(isMultiTool: Bool) -> [AgentHistoryGrouping] {
        AgentHistoryGrouping.allCases.filter { $0 != .tool || isMultiTool }
    }

    /// 逗号分隔的原始值。认不出的跳过（以后删掉的工具）；空串、或者一种都认不出 = 全部。
    static func decodeTools(_ raw: String) -> Set<AgentHistoryTool>? {
        let tools = Set(raw.split(separator: ",").compactMap { AgentHistoryTool(rawValue: String($0)) })
        return tools.isEmpty ? nil : tools
    }

    static func encodeTools(_ tools: Set<AgentHistoryTool>?) -> String {
        guard let tools else { return "" }
        return AgentHistoryTool.allCases.filter(tools.contains).map(\.rawValue).joined(separator: ",")
    }
}
