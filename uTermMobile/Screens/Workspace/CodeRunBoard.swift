import Foundation
import Observation

/// Code 标签页里「在这个标签页里继续聊天」的状态机：哪些会话正跑着一个活终端、详情此刻看的是哪一个、
/// 每个看终端还是看记录、新会话的占位怎么对上真实记录、终端里的程序退出后怎么回到记录。
///
/// 不沾界面也不沾 UIKit：终端是泛型 `Terminal`（App 里是 `TermTab`，测试里随便一个类），终端的事由外面报进来
/// （`ended`），连接、打字、关连接都在外面做。所以能单独测，以后和 Mac 那边的同类逻辑合成一份时只要把它挪进共享目录、
/// 把 `Terminal` 换成两端各自的终端会话即可。
///
/// 规则：
/// - 一份记录（`AgentHistorySessionFile.path`）至多一个活终端：再「继续」同一份就回到它，不另起。
/// - 点别的会话不打断正在跑的：每个 run 各留各的终端，`focused` 只是换详情看哪个。
/// - 新会话（「＋」）一开始没有记录，`sessionPath` 为 nil，列表最顶上单独一行「新会话」（`unlistedRuns`）。
///   之后外面拿主机上的会话列表来 `reconcile`：同一种工具、工作目录相同、修改时间不早于这个 run 起来之前
///   `matchSlack` 秒、还没被别的 run 认领的记录里，取修改时间最新的那份认下来（多个新会话按起来的先后依次认）。
///   认下来之后它就是那份记录的 run（再「继续」那份记录回到它），顶上那一行拿掉，回到那份记录平常的那一行（不自动置顶）；
///   对不上的一直留着占位（不丢），同一份记录不会被两个 run 认领（不重复）。
/// - 程序退出（`ended`）：跑了不到 `quickExit` 的留着终端给人看报错（命令没找到、目录不在了），标成已退出，
///   由用户「回到记录」或关掉；跑得够久的直接拿掉，详情回到那份记录（外面负责重新读到最新）。
@MainActor
@Observable
final class CodeRunBoard<Terminal: AnyObject> {
    struct Run: Identifiable {
        let id: UUID
        let tool: AgentHistoryTool
        /// 在哪个目录里跑的（「继续」是记录的工作目录，新会话是终端当时的目录）。
        let directory: String
        let startedAt: Date
        /// 对上的那份记录；新会话对上之前为 nil。
        var sessionPath: String?
        var sessionID: String?
        /// 详情看终端（true）还是看记录。没对上记录的只能看终端。
        var showsTerminal = true
        /// 程序退出的时刻（很快就退出、留着给人看的那种）；还在跑为 nil。
        var endedAt: Date?
        let terminal: Terminal

        var isNewSession: Bool { sessionPath == nil }
        var isRunning: Bool { endedAt == nil }
    }

    /// 程序退出时跑了不到这么久：留着终端给人看输出（多半是报错），不自动回到记录。测试改成 0。
    var quickExit: TimeInterval = 8
    /// 新会话对记录时，记录的修改时间可以比 run 起来的时刻早这么多（两边时钟、文件系统时间的粒度）。
    nonisolated static var matchSlack: TimeInterval { 5 }

    /// 按起来的先后。
    private(set) var runs: [Run] = []
    /// 详情正看着的 run；nil = 详情看普通的记录（或者什么都没选）。
    private(set) var focusedID: UUID?

    init() {}

    var focused: Run? { focusedID.flatMap(run(id:)) }
    /// 详情此刻显示的终端（看着某个 run、且它在看终端）。键盘归属、前台判定都看它。
    var shownTerminal: Terminal? {
        guard let focused, focused.showsTerminal else { return nil }
        return focused.terminal
    }
    var runningCount: Int { runs.filter(\.isRunning).count }

    func run(id: UUID) -> Run? { runs.first { $0.id == id } }
    func run(forSession path: String) -> Run? { runs.first { $0.sessionPath == path } }
    func run(for terminal: Terminal) -> Run? { runs.first { $0.terminal === terminal } }

    /// 列表里没有行的 run：还没对上记录的新会话，或者对上了但那份记录列表里还没列出来（还没重列、被「显示」筛掉、
    /// 还没翻到）。列表把它们放在最顶上，一个都不丢；列表里有行的不在这里（不重复）。`shown`：列表里显示着的记录。
    func unlistedRuns(shown: Set<String>) -> [Run] {
        runs.filter { run in run.sessionPath.map { !shown.contains($0) } ?? true }
    }

    // MARK: 起

    /// 「继续」一份记录：它已经有 run 就回到那个（看终端），返回 nil；没有就用 `make()` 建的终端起一个，返回它。
    @discardableResult
    func resume(sessionPath: String, sessionID: String, tool: AgentHistoryTool, directory: String,
                now: Date = Date(), make: () -> Terminal) -> Run? {
        if let existing = run(forSession: sessionPath) {
            focus(existing.id)
            setShowsTerminal(existing.id, true)
            return nil
        }
        let run = Run(id: UUID(), tool: tool, directory: directory, startedAt: now, sessionPath: sessionPath,
                      sessionID: sessionID, terminal: make())
        runs.append(run)
        focusedID = run.id
        return run
    }

    /// 「＋」新会话：总是新起一个（还没有记录可对）。
    @discardableResult
    func startNew(tool: AgentHistoryTool, directory: String, now: Date = Date(), terminal: Terminal) -> Run {
        let run = Run(id: UUID(), tool: tool, directory: directory, startedAt: now, terminal: terminal)
        runs.append(run)
        focusedID = run.id
        return run
    }

    // MARK: 看哪个

    /// 详情换成看这个 run（nil = 回到普通的记录 / 列表）。
    func focus(_ id: UUID?) {
        guard id == nil || run(id: id!) != nil else { return }
        focusedID = id
    }

    /// 「终端 / 记录」切换。没对上记录的新会话只能看终端。
    func setShowsTerminal(_ id: UUID, _ shows: Bool) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        if !shows, runs[index].sessionPath == nil { return }
        runs[index].showsTerminal = shows
    }

    // MARK: 退出

    enum EndOutcome: Equatable {
        /// 拿掉了；`sessionPath` 是它对上的记录（外面重新读到最新、详情回到它），新会话没对上为 nil。
        case removed(sessionPath: String?, wasFocused: Bool)
        /// 很快就退出：留着终端给人看，标成已退出。
        case kept
        case unknown
    }

    /// 终端里的程序退出了（shell 跟着结束、连接收尾）。
    @discardableResult
    func ended(_ id: UUID, now: Date = Date()) -> EndOutcome {
        guard let index = runs.firstIndex(where: { $0.id == id }), runs[index].endedAt == nil else { return .unknown }
        if now.timeIntervalSince(runs[index].startedAt) < quickExit {
            runs[index].endedAt = now
            return .kept
        }
        return remove(id)
    }

    /// 拿掉一个 run（已退出的「回到记录」、用户结束会话、挪成普通终端标签页）。看着它的话详情回到它的记录。
    @discardableResult
    func remove(_ id: UUID) -> EndOutcome {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return .unknown }
        let removed = runs.remove(at: index)
        let wasFocused = focusedID == id
        if wasFocused { focusedID = nil }
        return .removed(sessionPath: removed.sessionPath, wasFocused: wasFocused)
    }

    /// 标签页关了：全部拿掉，返回它们的终端（外面去关连接）。
    func removeAll() -> [Terminal] {
        let terminals = runs.map(\.terminal)
        runs = []
        focusedID = nil
        return terminals
    }

    // MARK: 新会话对上记录

    /// 外面看到的一份记录：路径、会话 ID、工具、工作目录（不知道为 nil，不参与认领）、修改时间。
    nonisolated struct Candidate: Equatable, Sendable {
        var path: String
        var sessionID: String
        var tool: AgentHistoryTool
        var directory: String?
        var modifiedAt: Date
    }

    /// 让还没对上记录的新会话认领记录（规则见类型注释）。返回这一轮认下来的 run。
    @discardableResult
    func reconcile(_ candidates: [Candidate]) -> [UUID] {
        var claimed = Set(runs.compactMap(\.sessionPath))
        var matched: [UUID] = []
        for index in runs.indices where runs[index].sessionPath == nil {
            let run = runs[index]
            let pick = candidates
                .filter { candidate in
                    candidate.tool == run.tool && !claimed.contains(candidate.path)
                        && candidate.modifiedAt >= run.startedAt.addingTimeInterval(-Self.matchSlack)
                        && candidate.directory.map { Self.sameDirectory($0, run.directory) } == true
                }
                .max { $0.modifiedAt < $1.modifiedAt }
            guard let pick else { continue }
            runs[index].sessionPath = pick.path
            runs[index].sessionID = pick.sessionID
            claimed.insert(pick.path)
            matched.append(run.id)
        }
        return matched
    }

    /// 还有没对上记录的新会话（外面据此决定要不要定期去主机上看一眼）。
    var hasUnmatchedNewSessions: Bool { runs.contains { $0.isNewSession && $0.isRunning } }

    nonisolated static func sameDirectory(_ a: String, _ b: String) -> Bool {
        func trimmed(_ path: String) -> String {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        return trimmed(a) == trimmed(b)
    }
}
