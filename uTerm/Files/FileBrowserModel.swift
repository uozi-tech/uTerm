import SwiftUI
import SwiftData

/// 文件浏览面板的状态机。导航/刷新/上传/下载经一个 `SFTPProviding`。
/// 生产用 `connect(...)` 建一个真实 `SFTPSession`；测试用 `init(testProvider:startPath:)`。
@MainActor
@Observable
final class FileBrowserModel {
    enum State: Equatable {
        case idle, connecting, browsing
        case failed(String)
    }

    enum SortKey: String, CaseIterable, Identifiable, Sendable {
        case name, size, modified
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: return "名称"
            case .size: return "大小"
            case .modified: return "修改时间"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var currentPath: String = "/"
    /// 由 provider 返回的原始顺序；UI 应读取 `sortedEntries`（已按当前偏好排好）。
    private(set) var entries: [RemoteEntry] = [] {
        didSet { recomputeSortedEntries() }
    }
    /// `entries` 经当前 sortKey / sortAscending / foldersFirst 排序后的缓存。
    ///
    /// 改成缓存（之前是 computed）：list 视图每次 body 重渲染都会读这条；如果
    /// 是 computed，SwiftUI 在 LazyList 滚动 + hover 触发的重渲染下会反复重新
    /// 过滤 + 排序 N 遍（n=条目数，最坏每秒数十次）。改成 stored cache，只在
    /// entries / sort 偏好变化时重算一次。
    private(set) var sortedEntries: [RemoteEntry] = []

    /// 排序偏好。改写后重新算 `sortedEntries`，并同步持久化到 UserDefaults
    /// （全局共享，所有 server 一致）。
    private enum PrefKey {
        static let sortKey       = "fileBrowser.sortKey"
        static let sortAscending = "fileBrowser.sortAscending"
        static let foldersFirst  = "fileBrowser.foldersFirst"
    }

    var sortKey: SortKey = {
        if let raw = UserDefaults.standard.string(forKey: PrefKey.sortKey),
           let k = SortKey(rawValue: raw) { return k }
        return .name
    }() {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: PrefKey.sortKey)
            recomputeSortedEntries()
        }
    }
    var sortAscending: Bool = {
        UserDefaults.standard.object(forKey: PrefKey.sortAscending) as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: PrefKey.sortAscending)
            recomputeSortedEntries()
        }
    }
    var foldersFirst: Bool = {
        UserDefaults.standard.object(forKey: PrefKey.foldersFirst) as? Bool ?? true
    }() {
        didSet {
            UserDefaults.standard.set(foldersFirst, forKey: PrefKey.foldersFirst)
            recomputeSortedEntries()
        }
    }

    /// 按当前排序偏好重算 `sortedEntries`。
    ///
    /// 稳定性 / nil 处理：
    /// - Swift 的 `Array.sorted` 不保证稳定 —— 用原始 index 做 tiebreaker
    ///   保证等值时按 provider 给的顺序排，列表不会跳。
    /// - size / modifiedAt 为 nil 时永远排最后（不受 ascending 翻转影响）。
    ///   之前用 `?? 0` 会让所有 dir（size=nil）撞 0、跟 0 字节文件混在一起。
    private func recomputeSortedEntries() {
        let ascending = sortAscending
        let key = sortKey

        func primary(_ a: RemoteEntry, _ b: RemoteEntry) -> ComparisonResult {
            switch key {
            case .name:
                return a.name.localizedStandardCompare(b.name)
            case .size:
                switch (a.size, b.size) {
                case let (sa?, sb?): return sa < sb ? .orderedAscending : (sa > sb ? .orderedDescending : .orderedSame)
                case (nil, nil):     return .orderedSame
                case (nil, _):       return .orderedDescending  // nil 总是更大 → 排末尾
                case (_, nil):       return .orderedAscending
                }
            case .modified:
                switch (a.modifiedAt, b.modifiedAt) {
                case let (ta?, tb?): return ta < tb ? .orderedAscending : (ta > tb ? .orderedDescending : .orderedSame)
                case (nil, nil):     return .orderedSame
                case (nil, _):       return .orderedDescending
                case (_, nil):       return .orderedAscending
                }
            }
        }

        // 给每一项打原始 index，等值时用 index 当 tiebreaker → 稳定排序。
        let indexed = entries.enumerated().map { (idx: $0.offset, e: $0.element) }

        func cmp(_ a: (idx: Int, e: RemoteEntry), _ b: (idx: Int, e: RemoteEntry)) -> Bool {
            let p = primary(a.e, b.e)
            if p != .orderedSame {
                // nil-end 路径：nil 总是 orderedDescending（更大），
                // 排序时无论 ascending 是 true / false，都要落到末尾。
                let aHasNilEnd: Bool = {
                    switch key {
                    case .name: return false
                    case .size: return a.e.size == nil || b.e.size == nil
                    case .modified: return a.e.modifiedAt == nil || b.e.modifiedAt == nil
                    }
                }()
                if aHasNilEnd {
                    return p == .orderedAscending
                }
                return ascending ? (p == .orderedAscending) : (p == .orderedDescending)
            }
            return a.idx < b.idx
        }

        if foldersFirst {
            let dirs  = indexed.filter {  $0.e.isDirectory }.sorted(by: cmp).map(\.e)
            let files = indexed.filter { !$0.e.isDirectory }.sorted(by: cmp).map(\.e)
            sortedEntries = dirs + files
        } else {
            sortedEntries = indexed.sorted(by: cmp).map(\.e)
        }
    }

    /// 主机密钥审批的 UI 桥接（驱动 `FileBrowserView` 的 sheet）。
    let hostKeyRelay = HostKeyChallengeRelay()

    private var provider: (any SFTPProviding)?
    private(set) var transientError: String?

    /// 供 FilePreviewModel 共享同一 SFTP 通道（避免一个 workspace 开两个 channel）。
    /// nil 表示尚未 connect。Spec 2A §1.4。
    var sftpProvider: (any SFTPProviding)? { provider }

    init() {}

    init(testProvider: any SFTPProviding, startPath: String) {
        self.provider = testProvider
        self.currentPath = startPath
        self.state = .browsing
    }

    func connect(profile: ServerProfile, modelContainer: ModelContainer) async {
        // 视图层 `.task(id:)` 会在视图重建时重新触发 connect；已连接/连接中则视为
        // no-op，不撕掉活动 SFTP 会话。仅 .idle（首次）/ .failed（重试）才继续。
        guard state == .idle || { if case .failed = state { return true } else { return false } }() else { return }
        state = .connecting
        // 任务被取消（如 sidebar 折叠 / 窗口关闭）时把 .connecting 重置回 .idle，
        // 否则下一次 connect 被 guard 直接跳过、永远停在 spinner 上（Fix #7）。
        defer {
            if Task.isCancelled, state == .connecting {
                state = .idle
            }
        }
        let keychain = KeychainStore()
        do {
            let auth = try SSHAuthResolver.resolve(profile: profile, keychain: keychain)
            var jumpAuth: ResolvedAuth?
            if let jump = profile.jumpHost {
                jumpAuth = try SSHAuthResolver.resolve(profile: jump, keychain: keychain)
            }
            let verifier = HostKeyVerifier(modelContainer: modelContainer)
            let approver = hostKeyRelay.makeApprover()
            let connected = try await SSHClientFactory.connect(
                profile: SSHConnection.ProfileSnapshot(profile),
                auth: auth, jumpHostAuth: jumpAuth,
                hostKeyVerifier: verifier, hostKeyApprover: approver)
            let session = try await SFTPSession(connected: connected)
            provider = session
            currentPath = (try? await session.realPath(".")) ?? "/"
            await refresh()
        } catch {
            state = .failed("\(error)")
        }
    }

    func refresh() async {
        guard let provider else { return }
        do {
            entries = try await provider.list(path: currentPath)
            state = .browsing
            transientError = nil
        } catch {
            state = .failed("\(error)")
        }
    }

    func navigate(into entry: RemoteEntry) async {
        guard entry.isDirectory else { return }
        currentPath = Self.join(currentPath, entry.name)
        await refresh()
    }

    func navigateUp() async {
        guard currentPath != "/" else { return }
        currentPath = Self.parent(of: currentPath)
        await refresh()
    }

    func download(entry: RemoteEntry) async -> Data? {
        guard let provider, !entry.isDirectory else { return nil }
        do {
            return try await provider.download(remotePath: Self.join(currentPath, entry.name))
        } catch {
            transientError = "下载失败：\(error)"
            return nil
        }
    }

    func upload(fileName: String, data: Data) async {
        guard let provider else { return }
        do {
            try await provider.upload(data: data, toRemotePath: Self.join(currentPath, fileName))
            await refresh()
        } catch {
            transientError = "上传失败：\(error)"
        }
    }

    func dispose() {
        hostKeyRelay.resolve(false)
        let p = provider
        provider = nil
        Task { await p?.close() }
    }

    /// 清除一次性错误（绑定到错误 alert 的关闭）。
    func clearTransientError() {
        transientError = nil
    }

    /// 服务器配置已删除等外部原因导致不可用时调用。
    func markUnavailable(_ message: String) {
        state = .failed(message)
    }

    static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        var comps = path.split(separator: "/", omittingEmptySubsequences: true)
        comps.removeLast()
        return comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
    }
}
