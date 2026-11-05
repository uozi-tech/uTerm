import Foundation
import Observation
import SwiftUI

/// 会话所在窗口的种类。`ControlTerminalSnapshot.windowKind` 的取值来源，
/// 客户端 / 技能文档里逐字出现，别改字面量。
nonisolated enum TerminalWindowKind {
    /// 完整工作区窗口（`WorkspaceWindowView`）。
    static let workspace = "workspace"
    /// 纯终端窗口（`TerminalWindowView`）。
    static let terminal = "terminal"
}

/// 一条跨窗口可见的终端会话。字段与 `ControlTerminalSnapshot` 一一对应
/// （那边是线上形状：UUID 变字符串、Date 变 ISO8601）。
///
/// `windowID` 是**唯一不上线**的字段：只用来把会话归到某个窗口，好让
/// `isKeyWindowFocused` 能由「窗口是不是 key」×「它的活动标签是不是我」算出来。
nonisolated struct TerminalSessionEntry: Identifiable, Sendable, Equatable {
    /// 会话 id（= `PaneModel` 的 id）。CLI 支持用唯一前缀指定。
    let id: UUID
    let serverID: UUID
    let serverName: String
    /// 会话所在窗口的 id（`WorkspaceWindowID.id` / `TerminalWindowID.id`）。不上线。
    let windowID: UUID
    /// `workspace` / `terminal` —— 会话所在窗口的种类。
    let windowKind: String
    /// 标签打开时定下的名字（`PaneModel.tabTitle`）优先，没有才是服务器名。
    var title: String
    let connectedAt: Date?

    init(
        id: UUID,
        serverID: UUID,
        serverName: String,
        windowID: UUID = UUID(),
        windowKind: String,
        title: String,
        connectedAt: Date? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.windowID = windowID
        self.windowKind = windowKind
        self.title = title
        self.connectedAt = connectedAt
    }

    /// 线上形状。`isKeyWindowFocused` **不存在 entry 里** —— 它是「窗口是不是 key」×
    /// 「它的活动标签是不是我」的派生值，唯一真值在注册表的 `windows` 里，
    /// 由 `TerminalSessionRegistry.snapshot(of:)` 读取时现算后传进来。
    func snapshot(isKeyWindowFocused: Bool) -> ControlTerminalSnapshot {
        ControlTerminalSnapshot(
            id: id.uuidString,
            serverID: serverID.uuidString,
            serverName: serverName,
            windowKind: windowKind,
            title: title,
            isKeyWindowFocused: isKeyWindowFocused,
            connectedAt: ControlProtocol.iso8601(connectedAt)
        )
    }
}

/// 跨窗口的终端会话注册表（app 级单例，注入 environment）。
///
/// uTerm 的终端会话住在各自窗口的 `WorkspaceModel` / `PaneModel` 里，彼此不可见；
/// CLI 的 `terminals` / `terminal-read` / `terminal-send` 需要一个应用级的枚举面，
/// 这就是它。`PaneModel.connect` 注册、`dispose` 注销。
///
/// 两条持有纪律：
/// - `entries` 是 **Sendable 值类型**数组（观察源），可以随便往协议层扔；
/// - `TerminalSession` 本体只以**弱引用**存在私有字典里 —— 注册表绝不延长任何会话的
///   寿命，窗口关掉就该释放。取会话时顺手清理已释放的槽位。
@MainActor
@Observable
final class TerminalSessionRegistry {

    /// 当前活着的会话，按注册顺序。
    private(set) var entries: [TerminalSessionEntry] = []

    /// 开一个新终端窗口，返回**新窗口的 id**（`TerminalWindowID.id`），拿不到时 nil。
    ///
    /// 由 app 在 Welcome 场景的 `.task` 里捕获 `openWindow` 后注入（`uTermApp` 里
    /// 既有的 `let open = openWindow` 写法同款）。`TerminalWindowID` 只能在 Scene
    /// 环境里开，所以注册表自己不能直接调。
    ///
    /// - Note: 返回的是**窗口** id 而不是会话 id —— `openWindow` 返回时会话还没建。
    ///   `terminal-open` 拿到窗口 id 后用 `waitForSession(inWindow:)` 等会话注册上来。
    var openTerminalWindow: (@MainActor (UUID) -> UUID?)?

    /// 开一个本机终端（工作目录为参数，nil = 主目录）：有本机终端窗口就加一个标签进去，没有才开窗口。返回**会话** id（预先定好的），
    /// 调用方用 `waitForSession(id:)` 等它登记——窗口里可能已经有别的会话，不能按窗口等。
    /// 注入方式与 `openTerminalWindow` 相同；手机远控的「新建本机终端」用它。
    var openLocalShell: (@MainActor (String?) -> UUID?)?

    /// 会话本体的弱引用槽（读屏 / 注入要拿到它）。
    @ObservationIgnored private var sessions: [UUID: WeakSessionBox] = [:]
    /// 每个窗口的 key / 活动标签状态，`isKeyWindowFocused` 由此算出。
    @ObservationIgnored private var windows: [UUID: WindowState] = [:]
    /// 每个窗口「按会话 id 关掉它的标签」的入口（手机远控关标签时可以连 Mac 上的一起关）。
    /// 返回 false = 这个窗口里没有这条会话。
    @ObservationIgnored private var closers: [UUID: @MainActor (UUID) -> Bool] = [:]

    /// 每个窗口「把这条会话的标签切到前台并带出窗口」的入口（点系统通知时用）。
    @ObservationIgnored private var revealers: [UUID: @MainActor (UUID) -> Bool] = [:]

    private final class WeakSessionBox {
        weak var value: TerminalSession?
        /// 登记时到底给没给会话本体。给了却读出 nil = 会话已被释放（幻影行，要清）；
        /// 一开始就没给（单测 / 占位登记）则不是幻影，别误清。
        let hadSession: Bool
        init(_ value: TerminalSession?) {
            self.value = value
            self.hadSession = value != nil
        }
        var isReleased: Bool { hadSession && value == nil }
    }

    private struct WindowState {
        var isKey = false
        var focusedSessionID: UUID?
    }

    init() {}

    // MARK: - 登记

    /// 会话连接成功后登记。同 id 重复登记视为**更新**（保留原插入位置）。
    func register(_ entry: TerminalSessionEntry, session: TerminalSession? = nil) {
        sessions[entry.id] = WeakSessionBox(session)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// 会话销毁时注销。
    func unregister(id: UUID) {
        sessions.removeValue(forKey: id)
        entries.removeAll { $0.id == id }
    }

    /// 窗口登记（或用 nil 撤掉）「按会话 id 关标签」的入口。
    func setCloser(forWindow windowID: UUID, _ closer: (@MainActor (UUID) -> Bool)?) {
        closers[windowID] = closer
    }

    /// 关掉某条会话所在的标签（连同它的连接 / shell）。返回 false = 找不到会话或它的窗口没登记入口。
    @discardableResult
    func requestClose(sessionID: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.id == sessionID }),
              let closer = closers[entry.windowID] else { return false }
        return closer(sessionID)
    }

    /// 标题变化（重命名标签 / 换服务器）时更新。会话不存在则 no-op。
    func update(id: UUID, title: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].title != title else { return }
        entries[index].title = title
    }

    func setRevealer(forWindow windowID: UUID, _ revealer: (@MainActor (UUID) -> Bool)?) {
        revealers[windowID] = revealer
    }

    /// 回到某条会话所在的标签。返回 false = 找不到会话或它的窗口没登记入口。
    @discardableResult
    func requestReveal(sessionID: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.id == sessionID }),
              let revealer = revealers[entry.windowID] else { return false }
        return revealer(sessionID)
    }

    /// 标签上显示的名字：程序设的标题优先，没有才是 `entry.title`（`zsh 2`、服务器名）。给系统通知和
    /// 手机用。程序设的标题可能每秒变很多次，所以不写进 `entries`，CLI 读到的 `title` 也保持稳定。
    func displayTitle(of entry: TerminalSessionEntry) -> String {
        let shellTitle = TerminalAttention.cleaned(sessions[entry.id]?.value?.shellTitle ?? "")
        return shellTitle.isEmpty ? entry.title : shellTitle
    }

    /// 这个会话对象登记时用的 id；没登记过则 nil。
    func sessionID(of session: TerminalSession) -> UUID? {
        sessions.first { $0.value.value === session }?.key
    }

    // MARK: - 窗口状态（喂 isKeyWindowFocused）

    /// 窗口成为 / 不再是 key window。窗口视图用 `\.controlActiveState` 驱动。
    func setKeyWindow(windowID: UUID, isKey: Bool) {
        var state = windows[windowID] ?? WindowState()
        guard state.isKey != isKey else { return }
        state.isKey = isKey
        windows[windowID] = state
    }

    /// 窗口内的活动终端标签变了。`nil` = 当前没有终端标签在前台。
    func setFocusedSession(_ sessionID: UUID?, inWindow windowID: UUID) {
        var state = windows[windowID] ?? WindowState()
        guard state.focusedSessionID != sessionID else { return }
        state.focusedSessionID = sessionID
        windows[windowID] = state
    }

    /// 窗口关闭时丢掉它的状态（会话本身由 `PaneModel.dispose` 各自注销）。
    func forgetWindow(_ windowID: UUID) {
        windows.removeValue(forKey: windowID)
        closers.removeValue(forKey: windowID)
        revealers.removeValue(forKey: windowID)
    }

    /// 某条会话此刻是不是「key window 的前台终端标签」。**读取时现算**，
    /// 不在 entry 里留缓存副本 —— 缓存要靠四个 mutator 手动同步，漏一个就说谎。
    func isKeyWindowFocused(_ id: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return isKeyWindowFocused(entry)
    }

    private func isKeyWindowFocused(_ entry: TerminalSessionEntry) -> Bool {
        guard let state = windows[entry.windowID] else { return false }
        return state.isKey && state.focusedSessionID == entry.id
    }

    // MARK: - 查询

    /// 线上形状（`terminals` 动作直接用）。读之前先清一次幻影行。
    func snapshots() -> [ControlTerminalSnapshot] {
        pruneReleasedSessions()
        return entries.map { $0.snapshot(isKeyWindowFocused: isKeyWindowFocused($0)) }
    }

    /// 单条会话的线上形状（`terminal-send` / `terminal-open` 的响应用）。
    func snapshot(of entry: TerminalSessionEntry) -> ControlTerminalSnapshot {
        entry.snapshot(isKeyWindowFocused: isKeyWindowFocused(entry))
    }

    /// 会话本体已被释放（窗口没走 `dispose` 就没了）的槽位：连 entry 一起清掉。
    ///
    /// 只清槽位不清 entry 的话，`terminals` 会永远列着一条读不了也写不了的幻影行，
    /// 模型对着它重试到超时。清扫在每个**读取**入口（`snapshots` / `matches` /
    /// `session(for:)`）前跑一次，代价是一次字典扫描。
    private func pruneReleasedSessions() {
        let dead = sessions.compactMap { $0.value.isReleased ? $0.key : nil }
        guard !dead.isEmpty else { return }
        for id in dead { sessions.removeValue(forKey: id) }
        entries.removeAll { dead.contains($0.id) }
    }

    /// 取会话本体。已被释放时顺手清掉槽位与 entry 并回 nil。
    func session(for id: UUID) -> TerminalSession? {
        pruneReleasedSessions()
        return sessions[id]?.value
    }

    /// 纯匹配：完整 id（忽略大小写）优先，否则按 uuidString 的**唯一前缀**。
    /// 返回 0 / 1 / 多条，由调用方决定报什么错。
    func matches(_ needle: String) -> [TerminalSessionEntry] {
        pruneReleasedSessions()
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let uuid = UUID(uuidString: trimmed),
           let hit = entries.first(where: { $0.id == uuid }) {
            return [hit]
        }
        let needleUpper = trimmed.uppercased()
        return entries.filter { $0.id.uuidString.hasPrefix(needleUpper) }
    }

    /// 按 id / 唯一前缀解析一条会话。
    /// 找不到 → `terminal_not_found`；多条 → `terminal_ambiguous`（消息里列候选）。
    func resolve(_ needle: String) throws(ControlFailure) -> TerminalSessionEntry {
        let hits = matches(needle)
        if hits.count == 1 { return hits[0] }
        if hits.isEmpty {
            throw ControlFailure(
                code: .terminal_not_found,
                message: "没有 id 以「\(needle)」开头的终端会话；先用 terminals 列一下"
            )
        }
        let candidates = hits.map { "\($0.id.uuidString)（\($0.serverName)）" }.joined(separator: "、")
        throw ControlFailure(
            code: .terminal_ambiguous,
            message: "「\(needle)」匹配到多条会话：\(candidates)。请用完整 id。"
        )
    }

    /// 等某条会话注册上来（本机终端用：会话 id 预先定好）。
    func waitForSession(
        id: UUID,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(100)
    ) async -> TerminalSessionEntry? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let hit = entries.first(where: { $0.id == id }) { return hit }
            guard ContinuousClock.now < deadline else { return nil }
            do { try await Task.sleep(for: pollInterval) } catch { return nil }
        }
    }

    /// 等某个窗口里的会话注册上来（`terminal-open` 用）。
    ///
    /// `openWindow` 返回时窗口还在异步搭建，会话要等 `PaneModel.connect` 成功才注册，
    /// 所以只能轮询。全程在 MainActor 上，`Task.sleep` 会让出 actor 给建连那条路。
    func waitForSession(
        inWindow windowID: UUID,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(100)
    ) async -> TerminalSessionEntry? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let hit = entries.first(where: { $0.windowID == windowID }) { return hit }
            guard ContinuousClock.now < deadline else { return nil }
            do { try await Task.sleep(for: pollInterval) } catch { return nil }
        }
    }
}

// MARK: - 登记入口（PaneModel 侧）

/// 一个窗口发给它旗下 `PaneModel` 的「登记凭条」：注册表 + 本窗口身份。
///
/// `PaneModel` 本身不知道自己在哪个窗口里，也不该去 environment 里捞；
/// `WorkspaceModel` 在窗口视图注入注册表时统一 stamp 给每个窗格。
/// 没 stamp（单测 / 预览）时凭条为 nil，注册与注销全是 no-op。
@MainActor
struct TerminalSessionRegistrar {
    let registry: TerminalSessionRegistry
    let windowID: UUID
    let windowKind: String
    /// `paneID` → 该窗格所在标签的名字（`PaneModel.tabTitle`）。
    ///
    /// 窗格自己不知道自己挂在哪条标签上（`PaneModel` 只有 `serverProfileID`），
    /// 标签树又只有 `WorkspaceModel` 拿得到，所以由它在 `attachSessionRegistry`
    /// 里注入这个查询钩子。返回 nil（没有名字 / 窗格还没进树 / 单测）时
    /// `title` 回落到服务器名。
    var customTitle: (@MainActor (UUID) -> String?)?

    init(
        registry: TerminalSessionRegistry,
        windowID: UUID,
        windowKind: String,
        customTitle: (@MainActor (UUID) -> String?)? = nil
    ) {
        self.registry = registry
        self.windowID = windowID
        self.windowKind = windowKind
        self.customTitle = customTitle
    }

    func register(
        paneID: UUID,
        serverID: UUID,
        serverName: String,
        session: TerminalSession,
        connectedAt: Date = Date()
    ) {
        registry.register(
            TerminalSessionEntry(
                id: paneID,
                serverID: serverID,
                serverName: serverName,
                windowID: windowID,
                windowKind: windowKind,
                title: customTitle?(paneID) ?? serverName,
                connectedAt: connectedAt
            ),
            session: session
        )
    }

    func unregister(paneID: UUID) {
        registry.unregister(id: paneID)
    }
}

// MARK: - 窗口接线

/// 把一个窗口的 `WorkspaceModel` 接到全局注册表上：注入凭条、跟踪 key window、
/// 跟踪活动标签。
///
/// 抽成 `ViewModifier` 而不是内联三个 `.task` / `.onChange`：
/// `WorkspaceWindowView.body` 已经贴着类型检查上限（文件里多处注释记着这件事），
/// 内联会把它推过去。
struct TerminalRegistryBinding: ViewModifier {
    let workspace: WorkspaceModel
    let windowID: UUID
    let windowKind: String

    @Environment(TerminalSessionRegistry.self) private var registry
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content
            .task {
                workspace.attachSessionRegistry(registry, windowID: windowID, windowKind: windowKind)
                registry.setKeyWindow(windowID: windowID, isKey: controlActiveState == .key)
                workspace.syncFocusedTerminalSession()
            }
            .onChange(of: controlActiveState) { _, state in
                registry.setKeyWindow(windowID: windowID, isKey: state == .key)
            }
            .onChange(of: workspace.focusedTerminalSessionID) { _, _ in
                workspace.syncFocusedTerminalSession()
            }
    }
}
