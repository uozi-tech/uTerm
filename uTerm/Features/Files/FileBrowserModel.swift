import Foundation
import Observation
import SwiftData

/// 远程文件浏览的状态机（macOS 与 iOS 共用）。导航 / 刷新 / 文件操作 / 传输都经一个 `SFTPProviding`。
///
/// 生产用 `connect(...)` 建真实 `SFTPSession`（`SFTPSession.make`）；测试用 `init(testProvider:startPath:)`。
/// macOS 的文件侧栏与 SFTP 窗口直接持有它（拖放 / 外部打开在 mac 专属的
/// `FileBrowserModel+Desktop.swift`）；iOS 的 `MobileSFTPController` 是它的一层转发壳。
///
/// 两端的有意差异做成参数：`sortOptions`（nil = macOS 读写排序偏好；iOS 固定显示点文件）、
/// `resolvesOwnerNames`（macOS 列完目录再经 exec 补属主名，iOS 不显示属主、不跑这一步）。
@MainActor
@Observable
final class FileBrowserModel {
    typealias SFTPConnector = @MainActor (
        _ profile: ServerProfile,
        _ modelContainer: ModelContainer,
        _ hostKeyRelay: HostKeyChallengeRelay
    ) async throws -> any SFTPProviding

    enum State: Equatable {
        case idle, connecting, browsing
        case failed(String)
    }

    /// 排序键已挪到两端共享的 `RemoteEntrySortKey`（`RemoteEntrySort.swift`），这里保留旧名。
    typealias SortKey = RemoteEntrySortKey

    enum TransferDirection: Sendable, Equatable { case up, down }

    /// 队列中的一次传输（上传或下载）。值类型，驱动传输 Dock / 列表。
    struct TransferItem: Identifiable, Equatable, Sendable {
        enum Status: Sendable, Equatable { case queued, active, done, failed }
        let id: UUID
        let fileName: String
        let direction: TransferDirection
        var bytesDone: Int64
        var bytesTotal: Int64
        var speedBytesPerSec: Double
        var status: Status
    }

    /// 递归删除的进度快照（两端共享的 `RemoteDeletionProgress`），这里保留旧名。
    typealias DeletionProgress = RemoteDeletionProgress

    private(set) var state: State = .idle
    /// 当前所在目录。只在目录**列成功之后**才改：列不出的目录不进去，留在原目录
    /// （首次建连除外，见 `connectUsingLastRequest`）。
    private(set) var currentPath: String = "/"
    /// 是否正在切到**别的**目录（或解析符号链接）。驱动 macOS 的加载盖层，
    /// 也是 `navigate(toPath:)` 的再入守卫。刷新当前目录不算。
    private(set) var isNavigating = false
    /// 是否有目录加载在途（含刷新当前目录）。iOS 的 `loading` 读它。
    private(set) var isLoading = false
    /// 由 provider 返回的原始顺序；UI 应读取 `sortedEntries`（已按当前偏好排好）。
    private(set) var entries: [RemoteEntry] = []
    /// `entries` 经当前排序选项排好、滤过隐藏文件后的缓存。
    ///
    /// 缓存而不是 computed：列表视图每次 body 重渲染都会读这条；如果是 computed，SwiftUI 在
    /// LazyList 滚动 + hover 触发的重渲染下会反复重新过滤 + 排序 N 遍。只在 entries / 排序偏好
    /// 变化时重算一次。新列表的排序在并发线程池里做（上万条要几十万次本地化比较），不占主线程。
    private(set) var sortedEntries: [RemoteEntry] = []

    /// 排序偏好（macOS 全局共享，所有 server 一致，存 UserDefaults）。
    private enum PrefKey {
        static let sortKey       = DefaultsKey.fileBrowserSortKey
        static let sortAscending = DefaultsKey.fileBrowserSortAscending
        static let foldersFirst  = DefaultsKey.fileBrowserFoldersFirst
        static let showHidden    = DefaultsKey.fileBrowserShowHidden
    }

    /// 非 nil = 排序固定成这一套、不读写偏好（iOS）；nil = 读写 macOS 的排序偏好。
    @ObservationIgnored private let persistsSortPreferences: Bool
    /// 列完目录后是否经 exec 补属主 / 属组名（macOS 显示，iOS 不显示）。
    @ObservationIgnored private let resolvesOwnerNames: Bool

    // 每项只写自己那个键：几个窗口各缓存一份时，改「显示隐藏文件」不能把自己那份过时的排序方式也写回去，
    // 盖掉别的窗口刚改的。别的窗口写了，经 `sortPreferenceObserver` 同步过来。
    var sortKey: SortKey = .name {
        didSet { persistSortPreference(sortKey.rawValue, oldValue != sortKey, PrefKey.sortKey); recomputeSortedEntries() }
    }
    var sortAscending = true {
        didSet { persistSortPreference(sortAscending, oldValue != sortAscending, PrefKey.sortAscending); recomputeSortedEntries() }
    }
    var foldersFirst = true {
        didSet { persistSortPreference(foldersFirst, oldValue != foldersFirst, PrefKey.foldersFirst); recomputeSortedEntries() }
    }
    var showHidden = false {
        didSet { persistSortPreference(showHidden, oldValue != showHidden, PrefKey.showHidden); recomputeSortedEntries() }
    }

    /// 读写偏好时监听别处（另一个窗口 / 标签）改了排序，跟着变。
    @ObservationIgnored nonisolated(unsafe) private var sortPreferenceObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isSyncingSortPreferences = false

    var sortOptions: RemoteEntrySortOptions {
        RemoteEntrySortOptions(key: sortKey, ascending: sortAscending,
                               foldersFirst: foldersFirst, showHidden: showHidden)
    }

    private static func persistedSortOptions() -> RemoteEntrySortOptions {
        let defaults = UserDefaults.standard
        return RemoteEntrySortOptions(
            key: defaults.string(forKey: PrefKey.sortKey).flatMap(SortKey.init(rawValue:)) ?? .name,
            ascending: defaults.object(forKey: PrefKey.sortAscending) as? Bool ?? true,
            foldersFirst: defaults.object(forKey: PrefKey.foldersFirst) as? Bool ?? true,
            showHidden: defaults.object(forKey: PrefKey.showHidden) as? Bool ?? false)
    }

    private func persistSortPreference(_ value: Any, _ changed: Bool, _ key: String) {
        guard persistsSortPreferences, changed, !isSyncingSortPreferences else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func observeSortPreferences() {
        sortPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSortPreferences() }
        }
    }

    private func syncSortPreferences() {
        let stored = Self.persistedSortOptions()
        guard stored != sortOptions else { return }
        isSyncingSortPreferences = true
        defer { isSyncingSortPreferences = false }
        applySortOptions(stored)
    }

    deinit {
        if let sortPreferenceObserver { NotificationCenter.default.removeObserver(sortPreferenceObserver) }
    }

    private func applySortOptions(_ options: RemoteEntrySortOptions) {
        sortKey = options.key
        sortAscending = options.ascending
        foldersFirst = options.foldersFirst
        showHidden = options.showHidden
    }

    /// 排序偏好变了：同步重排（用户操作触发，条目已在手里）。规则在共享的 `RemoteEntrySort`。
    private func recomputeSortedEntries() {
        sortedEntries = RemoteEntrySort.sorted(entries, options: sortOptions)
    }

    /// 新列表的排序放到并发线程池里。排序期间偏好被改了就按新偏好在主线程补排一次。
    private func sortedForDisplay(_ list: [RemoteEntry]) async -> [RemoteEntry] {
        let options = sortOptions
        let sorted = await Self.sortedOffMain(list, options: options)
        return options == sortOptions ? sorted : RemoteEntrySort.sorted(list, options: sortOptions)
    }

    @concurrent nonisolated private static func sortedOffMain(
        _ list: [RemoteEntry],
        options: RemoteEntrySortOptions
    ) async -> [RemoteEntry] {
        RemoteEntrySort.sorted(list, options: options)
    }

    /// 主机密钥审批的 UI 桥接（驱动 macOS `FileBrowserView` 的 sheet）。iOS 建连时传自己工作区的
    /// relay（`connect(..., hostKeyRelay:)`），这一份就不用。
    let hostKeyRelay = HostKeyChallengeRelay()

    private var provider: (any SFTPProviding)?
    let remoteDragScopeID = UUID()
    private(set) var transientError: String?
    /// 传输队列（上传 + 下载）。仅 standalone SFTP 窗口渲染；侧边栏不写。
    private(set) var transfers: [TransferItem] = []
    /// 正在进行的递归删除；nil = 无。同一时刻只允许一个（见 `beginDelete` 的守卫）。
    private(set) var deletion: DeletionProgress?
    /// 取消旗标。`cancelDeletion()` / `dispose()` 置位，删除循环在每次往返前检查。
    @ObservationIgnored private var deletionCancelled = false
    @ObservationIgnored private var ownerEnrichmentTask: Task<Void, Never>?

    /// 目录加载代次：每次加载（含符号链接解析）递增，晚到的旧结果直接丢弃 —— 网速慢时先点 A
    /// 再点 B，A 后返回不能把列表和路径改回 A。`dispose()` 也递增，关掉后不再落任何结果。
    @ObservationIgnored private var loadGeneration = 0
    /// 在途加载的目标目录。加载期间触发的刷新（如上传完成）列它而不是旧目录，
    /// 否则刷新会把刚发起的切换顶掉。
    @ObservationIgnored private var pendingPath: String?
    /// 建连代次：`dispose()` / 新一次建连递增；在途建连落地时对不上就关掉刚建的会话。
    @ObservationIgnored private var connectGeneration = 0
    /// `dispose()` 之后为 true：晚到的失败没人看，不再写提示。
    @ObservationIgnored private var isDisposed = false

    /// 每个传输的不可展示状态：数据来源、取消句柄、测速采样点。
    /// MainActor 隔离，用 class 便于原地改可变字段。
    private final class TransferContext {
        enum Source {
            case uploadURL(URL)
            case uploadData(Data)
            case download(remotePath: String, localURL: URL)
        }
        let source: Source
        /// 入队时捕获的目标目录（上传用）。槽位激活时机不确定，若上传时再读 live
        /// `currentPath` 会把排队中的上传落到当时正好停留的目录（用户已切走）；故在
        /// `enqueueUploads`/`enqueueUpload` 入队那一刻就锚定目录，传输/重试都用它。
        /// 下载项不用此字段（remotePath 在下载入口已锚定）。
        let destinationDir: String
        var cancel: (() -> Void)?
        var downloadCompletion: ((Bool) -> Void)?
        var lastSampleTime: Date?
        var lastSampleBytes: Int64 = 0
        init(source: Source, destinationDir: String) {
            self.source = source
            self.destinationDir = destinationDir
        }
    }
    private var contexts: [UUID: TransferContext] = [:]

    /// `TransferItem.id → transfers 下标`。
    ///
    /// **为什么要它**：进度回调走 `applyProgress`，改前用 `transfers.firstIndex(where:)`
    /// 找行 —— O(队列长度)。而传输行**不会自动清**（完成 / 失败的留着等用户点
    /// 「清除已完成」），新起的传输永远排在一堆已完成行的后面，于是每一次进度回调
    /// 都要先扫过那一堆。实测历史 20 条 0.00202ms/次 → 历史 1000 条 0.07064ms/次（35×）。
    /// 结构变更（增删）时重建一次；改元素值不动下标。
    @ObservationIgnored private var transferIndexByID: [UUID: Int] = [:]

    /// 上传和下载共用的总并发预算（用户设置；默认 4，钳 1…64）。
    static var maxConcurrentTransfers: Int {
        let raw = UserDefaults.standard.object(forKey: DefaultsKey.sftpMaxConcurrentTransfers) as? Int ?? 4
        return min(64, max(1, raw))
    }
    /// 测试用的固定上限：测试宿主的 `UserDefaults.standard` 就是正式版的设置，不能写。
    private let fixedConcurrencyLimit: Int?
    private static let transferSpeedSampleInterval: TimeInterval = 0.10

    private var restoredInitialPath: String?
    /// 是否成功浏览过至少一次。重连「保留当前目录」只在浏览过后才成立 ——
    /// 首次连接就失败时 `currentPath` 还是占位 "/"，强行保留会把重连后的
    /// 起始目录从用户家目录钉死到根目录。也用来区分「列目录失败」该翻失败页还是只给提示。
    private var didEverBrowse = false
    private let sftpConnector: SFTPConnector
    @ObservationIgnored private var lastConnectionRequest: ConnectionRequest?
    /// 失败态是建连时「重试也不会好」的那种（凭据被拒、主机密钥被拒、握手不成——`SSHTransportFailure.isPermanentConnectFailure`）：
    /// 看门狗不再自动重试（否则每次心跳都再登录失败一次，可能触发服务器的 fail2ban / pam_faillock），等用户自己点重试。
    @ObservationIgnored private(set) var failureNeedsUser = false

    private struct ConnectionRequest {
        let profile: ServerProfile
        let modelContainer: ModelContainer
        let hostKeyRelay: HostKeyChallengeRelay
    }

    /// 供 FilePreviewModel 共享同一 SFTP 通道（避免一个 workspace 开两个 channel）。
    /// nil 表示尚未 connect。Spec 2A §1.4。
    var sftpProvider: (any SFTPProviding)? { provider }
    /// 当前连接的主机。尚未 connect（或已 `dispose` / `markUnavailable`）时为 nil。
    var connectedProfile: ServerProfile? { lastConnectionRequest?.profile }
    var snapshotCurrentPath: String? {
        state == .browsing || restoredInitialPath != nil ? currentPath : nil
    }

    /// - Parameters:
    ///   - sortOptions: nil = 读写 macOS 的排序偏好；非 nil = 固定这一套、不持久化（iOS）。
    ///   - resolvesOwnerNames: 列完目录后是否补属主 / 属组名。
    init(sftpConnector: @escaping SFTPConnector = FileBrowserModel.makeLiveSFTPProvider,
         sortOptions: RemoteEntrySortOptions? = nil,
         resolvesOwnerNames: Bool = true) {
        self.fixedConcurrencyLimit = nil
        self.sftpConnector = sftpConnector
        self.persistsSortPreferences = sortOptions == nil
        self.resolvesOwnerNames = resolvesOwnerNames
        applySortOptions(sortOptions ?? Self.persistedSortOptions())
        if persistsSortPreferences { observeSortPreferences() }
    }

    /// 已经连好的文件通道（远程 Mac：连接归远控链路管，本模型不建连、不重连）。
    /// 建好后调 `load(startPath)` 列第一屏。`dispose()` 只是不再用它，通道本身由调用方管。
    init(provider: any SFTPProviding, startPath: String,
         sortOptions: RemoteEntrySortOptions? = nil, resolvesOwnerNames: Bool = false) {
        self.fixedConcurrencyLimit = nil
        self.sftpConnector = { _, _, _ in provider }
        self.persistsSortPreferences = sortOptions == nil
        self.resolvesOwnerNames = resolvesOwnerNames
        self.provider = provider
        self.currentPath = startPath
        self.state = .browsing
        applySortOptions(sortOptions ?? Self.persistedSortOptions())
        if persistsSortPreferences { observeSortPreferences() }
    }

    init(testProvider: any SFTPProviding, startPath: String, maxConcurrentTransfers: Int = 4,
         sortOptions: RemoteEntrySortOptions? = nil, resolvesOwnerNames: Bool = true) {
        self.fixedConcurrencyLimit = maxConcurrentTransfers
        self.sftpConnector = { _, _, _ in testProvider }
        self.persistsSortPreferences = false
        self.resolvesOwnerNames = resolvesOwnerNames
        self.provider = testProvider
        self.currentPath = startPath
        self.state = .browsing
        applySortOptions(sortOptions ?? Self.persistedSortOptions())
    }

    /// 连到一台主机。视图层 `.task(id:)` 重建时会重复调用：已连接 / 连接中是 no-op，
    /// 只有 `.idle`（首次）/ `.failed`（重试）才真去建连。
    ///
    /// - Parameter hostKeyRelay: 首连主机密钥审批走哪一个 relay；nil = 本模型自己的
    ///   `hostKeyRelay`（macOS）。iOS 传工作区共用的那一份。
    func connect(profile: ServerProfile, modelContainer: ModelContainer,
                 hostKeyRelay relay: HostKeyChallengeRelay? = nil) async {
        // 注册到看门狗：系统唤醒 / 网络恢复后主动探测，半死连接不再静默挂着。
        ConnectionWatchdog.shared.register(self)
        isDisposed = false
        lastConnectionRequest = ConnectionRequest(
            profile: profile, modelContainer: modelContainer,
            hostKeyRelay: relay ?? hostKeyRelay)
        await connectUsingLastRequest(force: false, initialPath: nil)
    }

    private func connectUsingLastRequest(force: Bool, initialPath: String?,
                                         waitForOwnerNames: Bool = true) async {
        guard let request = lastConnectionRequest else { return }
        guard force || state == .idle || Self.isFailed(state) else { return }
        // 失败态重试时旧会话可能还在（目录列失败而不是连接断了）：先关掉，免得被新会话顶掉后泄漏。
        if provider != nil {
            closeCurrentProvider()
        }
        connectGeneration &+= 1
        let attempt = connectGeneration
        state = .connecting
        failureNeedsUser = false
        // 任务被取消（如 sidebar 折叠 / 窗口关闭）时把 .connecting 重置回 .idle，
        // 否则下一次 connect 被 guard 直接跳过、永远停在 spinner 上（Fix #7）。
        defer {
            if Task.isCancelled, state == .connecting, connectGeneration == attempt {
                state = .idle
            }
        }
        let timeline = ConnectTimeline(kind: "sftp", target: request.profile.timingTarget)
        await ConnectTimeline.$current.withValue(timeline) {
            do {
                let session = try await sftpConnector(
                    request.profile, request.modelContainer, request.hostKeyRelay)
                // 建连期间被 `dispose()` / 新一次建连取代：这条会话没人要了，关掉而不是挂在那里。
                guard connectGeneration == attempt else {
                    timeline.finish("superseded")
                    await session.close()
                    return
                }
                provider = session
                let startPath: String
                if let initialPath {
                    startPath = initialPath
                } else if let restoredInitialPath {
                    startPath = restoredInitialPath
                    self.restoredInitialPath = nil
                } else {
                    startPath = (try? await session.realPath(".")) ?? "/"
                    timeline.mark("realPath")
                    guard connectGeneration == attempt else { return }
                }
                // 首次建连先落路径：起始目录列失败时失败页 / 重连也认这个目录。
                currentPath = startPath
                await load(startPath, reconnectOnTransportFailure: false,
                           waitForOwnerNames: waitForOwnerNames)
                timeline.finish(state == .browsing ? "ok" : "list failed")
            } catch {
                timeline.finish("failed")
                guard connectGeneration == attempt else { return }
                provider = nil
                failureNeedsUser = SSHTransportFailure.isPermanentConnectFailure(error)
                state = .failed(FriendlyError.describe(error))
            }
        }
    }

    /// 生产建连：由主机解析凭据并建 SFTP 会话（`SFTPSession.make`，与终端同一套凭据解析 + 共享连接池）。
    private static func makeLiveSFTPProvider(
        profile: ServerProfile,
        modelContainer: ModelContainer,
        hostKeyRelay: HostKeyChallengeRelay
    ) async throws -> any SFTPProviding {
        try await SFTPSession.make(profile: profile, container: modelContainer,
                                   approver: hostKeyRelay.makeApprover())
    }

    func restoreCurrentPath(_ path: String) {
        guard !path.isEmpty else { return }
        currentPath = path
        restoredInitialPath = path
    }

    /// 重新列当前目录（有切换在途时列它的目标）。连接已断会自动重连并保留目录。
    func refresh() async {
        await load(pendingPath ?? currentPath, reconnectOnTransportFailure: true,
                   waitForOwnerNames: true)
    }

    /// Agent 命令后的关键路径只等待目录列表。owner/group 的 exec 补全在后台继续，
    /// 让模型续轮不再被每 80 项一次的串行 shell 往返阻塞。
    func refreshListingAfterRemoteCommand() async {
        await load(pendingPath ?? currentPath, reconnectOnTransportFailure: true,
                   waitForOwnerNames: false)
    }

    /// 列一个目录并进去（iOS 的进目录 / 面包屑，及刷新）。后发者胜：在途的旧加载结果直接丢弃。
    /// 与 `navigate(toPath:)` 的区别：不做「同一目录 / 有切换在途」的守卫。
    func load(_ path: String) async {
        await load(path, reconnectOnTransportFailure: true, waitForOwnerNames: true)
    }

    private func load(_ target: String, reconnectOnTransportFailure: Bool,
                      waitForOwnerNames: Bool) async {
        guard let provider else {
            if reconnectOnTransportFailure {
                _ = await reconnectPreservingCurrentPath(at: target,
                                                         waitForOwnerNames: waitForOwnerNames)
            }
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        ownerEnrichmentTask?.cancel()
        ownerEnrichmentTask = nil
        pendingPath = target
        isLoading = true
        isNavigating = target.remoteKey != currentPath.remoteKey
        do {
            let listed = try await provider.list(path: target)
            let sorted = await sortedForDisplay(listed)
            guard generation == loadGeneration else { return }
            // 先发布 SFTP 原始 uid/gid；名字补全不是目录正确性的前置条件。
            finishLoad(at: target, listed: listed, sorted: sorted)
            // 列表此刻已上屏；属主名补全在后面单独计。
            ConnectTimeline.current?.mark("list(\(listed.count))")
            guard resolvesOwnerNames else { return }
            if waitForOwnerNames {
                let enriched = await resolveOwnerNames(
                    for: listed, provider: provider, directoryPath: target)
                await publishOwnerEnrichment(enriched, generation: generation, directoryPath: target)
                ConnectTimeline.current?.mark("ownerNames")
            } else {
                ownerEnrichmentTask = Task { [weak self, provider] in
                    guard let self else { return }
                    let enriched = await self.resolveOwnerNames(
                        for: listed, provider: provider, directoryPath: target)
                    guard !Task.isCancelled else { return }
                    await self.publishOwnerEnrichment(
                        enriched, generation: generation, directoryPath: target)
                }
            }
        } catch {
            guard generation == loadGeneration else { return }
            settleLoading()
            let isTransport = Self.isRecoverableTransportError(error)
            if reconnectOnTransportFailure, isTransport, canReconnect {
                _ = await reconnectPreservingCurrentPath(at: target,
                                                         waitForOwnerNames: waitForOwnerNames)
                return
            }
            if state == .browsing, didEverBrowse, !isTransport {
                // 已经在浏览：列不出的目录（权限不足 / 不存在）不进去，留在原目录给个提示。
                // 整页翻成失败只留给连接本身的问题与首次列目录。
                transientError = String(localized: "打开文件夹失败：\(FriendlyError.describe(error))")
            } else {
                state = .failed(FriendlyError.describe(error))
            }
        }
    }

    private func finishLoad(at path: String, listed: [RemoteEntry], sorted: [RemoteEntry]) {
        // 路径、列表与加载态在同一次同步更新里落地：盖层一撤就直接是新列表，不露旧目录。
        currentPath = path
        entries = listed
        sortedEntries = sorted
        state = .browsing
        didEverBrowse = true
        transientError = nil
        settleLoading()
    }

    private func settleLoading() {
        isLoading = false
        isNavigating = false
        pendingPath = nil
    }

    private func publishOwnerEnrichment(_ enriched: [RemoteEntry],
                                        generation: Int,
                                        directoryPath: String) async {
        guard generation == loadGeneration, currentPath.remoteKey == directoryPath.remoteKey else { return }
        let sorted = await sortedForDisplay(enriched)
        guard generation == loadGeneration, currentPath.remoteKey == directoryPath.remoteKey else { return }
        entries = enriched
        sortedEntries = sorted
    }

    private var canReconnect: Bool {
        lastConnectionRequest != nil && state != .connecting
    }

    private func reconnectPreservingCurrentPath(at path: String? = nil,
                                                waitForOwnerNames: Bool = true) async -> Bool {
        guard canReconnect else { return false }
        await connectUsingLastRequest(force: true,
                                      initialPath: didEverBrowse ? (path ?? currentPath) : nil,
                                      waitForOwnerNames: waitForOwnerNames)
        return state == .browsing
    }

    func navigate(into entry: RemoteEntry) async {
        guard entry.isDirectory else { return }
        await navigate(toPath: Self.join(currentPath, entry.name))
    }

    func navigateUp() async {
        guard currentPath != "/" else { return }
        await navigate(toPath: Self.parent(of: currentPath))
    }

    /// 直接跳到绝对路径（供 macOS 面包屑 / 历史栈 / 前进后退 / `..` 驱动）。
    ///
    /// 再入守卫：一次目录切换的网络往返还没回来时，重复点击直接忽略 —— 前进 / 后退的历史下标
    /// 由视图在调用前移动，放行第二次会让下标与 `currentPath` 脱钩。`isNavigating` 同时驱动
    /// 视图加载态，让单击立刻有反馈。
    func navigate(toPath path: String) async {
        guard path.remoteKey != currentPath.remoteKey, !isNavigating else { return }
        await load(path)
    }

    /// 点击符号链接时懒解析：沿链接路径探测 —— `opendir` 跟随符号链接，能列出即
    /// 目标是目录，直接进入（复用探测到的列表，省一次往返）；否则当文件，`stat`
    /// 跟随链接取目标 size/mtime 返回，由调用方去打开（侧栏预览）/ 下载（独立窗口）/ 弹操作单（iOS）。
    ///
    /// 返回 nil = 已进入目录（或非 symlink / 被更新的加载取代）；非 nil = 目标是文件。
    /// 与目录加载共用代次：解析期间用户又点了别的目录，晚到的结果直接丢弃。
    /// 全程置 `isNavigating`，让侧栏加载层在解析往返期间盖住列表、不露旧目录。
    ///
    /// - Parameter directory: 链接所在目录；nil = 当前目录。
    func resolveSymlinkForOpen(_ entry: RemoteEntry, in directory: String? = nil) async
        -> (path: String, size: Int64?, mtime: Date?)? {
        guard let provider, entry.isSymlink else { return nil }
        loadGeneration &+= 1
        let generation = loadGeneration
        ownerEnrichmentTask?.cancel()
        ownerEnrichmentTask = nil
        isLoading = true
        isNavigating = true
        let target = await RemoteFileOperations.resolveSymlink(
            entry, in: directory ?? currentPath, provider: provider)
        guard generation == loadGeneration else { return nil }
        switch target {
        case .directory(let linkPath, let targetEntries):
            let named = resolvesOwnerNames
                ? await resolveOwnerNames(for: targetEntries, provider: provider, directoryPath: linkPath)
                : targetEntries
            let sorted = await sortedForDisplay(named)
            guard generation == loadGeneration else { return nil }
            finishLoad(at: linkPath, listed: named, sorted: sorted)
            return nil
        case .file(let linkPath, let size, let mtime):
            settleLoading()
            return (linkPath, size, mtime)
        }
    }

    // MARK: - 文件操作
    //
    // 带 `in directory:` 的操作：nil = 当前目录。iOS 的操作单从长按到确认之间隔着动画与确认框，
    // 这期间当前目录可能已经换了，调用方传长按那一刻的目录。

    func upload(fileName: String, data: Data) async {
        guard let provider else { return }
        do {
            try await provider.upload(data: data, toRemotePath: Self.join(currentPath, fileName))
            await refresh()
        } catch {
            report(error, action: String(localized: "上传", comment: "操作名，接在「…失败：原因」前"))
        }
    }

    /// 不进传输队列的单文件流式上传（iOS 文件标签：没有传输 Dock，失败直接提示）。
    /// 不先把整个文件读进内存。
    func upload(localURL url: URL, in directory: String? = nil) async {
        guard let provider else { return }
        let destination = Self.join(directory ?? currentPath, url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try await provider.upload(localURL: url, toRemotePath: destination, onProgress: nil)
            await refresh()
        } catch {
            report(error, action: String(localized: "上传", comment: "操作名，接在「…失败：原因」前"))
        }
    }

    func makeDirectory(name: String) async {
        guard let provider else { return }
        do {
            try await provider.createDirectory(Self.join(currentPath, name))
            await refresh()
        } catch { report(error, action: String(localized: "新建文件夹", comment: "操作名，接在「…失败：原因」前")) }
    }

    /// 在当前目录新建一个空文件（fail-if-exists，见 `SFTPProviding.createFile`）。
    func makeFile(name: String) async {
        guard let provider else { return }
        do {
            try await provider.createFile(Self.join(currentPath, name))
            await refresh()
        } catch { report(error, action: String(localized: "新建文件", comment: "操作名，接在「…失败：原因」前")) }
    }

    /// 同目录改名。名字去首尾空白；空名或没变不发请求、也不刷新（共享的
    /// `RemoteFileOperations.rename`）。
    func rename(entry: RemoteEntry, to newName: String, in directory: String? = nil) async {
        guard let provider else { return }
        do {
            guard try await RemoteFileOperations.rename(
                entry, to: newName, in: directory ?? currentPath, provider: provider) else { return }
            await refresh()
        } catch { report(error, action: String(localized: "重命名", comment: "操作名，接在「…失败：原因」前")) }
    }

    /// 删除一个条目（等它结束）。见 `beginDelete`。
    func delete(entry: RemoteEntry, in directory: String? = nil) async {
        await beginDelete(entry, in: directory)?.value
    }

    /// 发起删除，返回执行它的任务（守卫没过返回 nil）。文件 = 一次 `removeFile`；目录 = 枚举整棵
    /// 子树后逐项删，全程把进度写进 `deletion` 驱动进度条，并可中途取消（`cancelDeletion()`）。
    ///
    /// 守卫与进度在**调用这一刻**同步落地（iOS 是发射后不管的调用，要立刻有进度可显示、
    /// 第二次删除立刻提示）。无论成功 / 失败 / 取消，收尾都会 `refresh()` —— 失败或取消时远端
    /// 多半已被删掉一部分，列表必须跟着变。错误消息在 refresh **之后**再置，因为 refresh 成功会
    /// 清空 `transientError`。
    @discardableResult
    func beginDelete(_ entry: RemoteEntry, in directory: String? = nil) -> Task<Void, Never>? {
        guard let provider else { return nil }
        // 同一条 SFTP 通道上一次只跑一个删除任务。静默吞掉第二次请求会让用户
        // 以为点击没生效（他刚在确认框上按了「删除」），故明确说一声。
        if let running = deletion {
            transientError = String(localized: "正在删除「\(running.name)」，等它结束后再删下一项。")
            return nil
        }
        let dir = directory ?? currentPath
        if entry.isDirectory {
            deletionCancelled = false
            deletion = .starting(entry.name)
        }
        return Task { [weak self] in
            var failure: Error?
            do {
                try await RemoteFileOperations.delete(
                    entry, in: dir, provider: provider,
                    isCancelled: { self?.deletionCancelled ?? true },
                    onProgress: { self?.deletion?.apply($0) })
            } catch is RemoteFileOperations.DeletionCancelled {
                // 用户主动取消：不是错误，只把已删掉的部分刷出来。
            } catch {
                failure = error
            }
            guard let self else { return }
            self.deletion = nil
            await self.refresh()
            if let failure { self.report(failure, action: String(localized: "删除", comment: "操作名，接在「…失败：原因」前"), reconnect: false) }
        }
    }

    /// 请求中止正在进行的递归删除。已经删掉的部分不会回滚（SFTP 没有事务），
    /// 中止后照常刷新列表把剩下的显示出来。
    func cancelDeletion() {
        guard deletion != nil, !deletionCancelled else { return }
        deletionCancelled = true
        deletion?.isCancelling = true
    }

    /// 设置文件 / 文件夹权限（chmod）。`mode` 取低 9 位（`& 0o777`）。
    /// - 非递归（或文件）：走 SFTP `setstat`（`provider.setPermissions`）。
    /// - 递归（目录 + `recursive`）：开 exec channel 跑 `chmod -R <oct> <path>`，
    ///   一次性把整棵子树改掉（比逐项 setstat 可靠且快）。
    /// 完成后刷新列表；失败置 `transientError`。
    func setPermissions(entry: RemoteEntry, mode: UInt32, recursive: Bool,
                        in directory: String? = nil) async {
        guard let provider else { return }
        do {
            try await RemoteFileOperations.setPermissions(
                entry, in: directory ?? currentPath, mode: mode, recursive: recursive,
                provider: provider)
            await refresh()
        } catch { report(error, action: String(localized: "权限设置", comment: "操作名，接在「…失败：原因」前")) }
    }

    /// 把一次操作失败落成「操作失败」提示（`<动作>失败：<原因>`），浏览照常。
    /// 连接已断（传输层错误）时再刷新一次：`refresh()` 会自动重连并保留目录，重连不上才翻失败页。
    ///
    /// - Parameter reconnect: 调用方已经刷新过（如删除收尾）时传 false，免得重复列目录。
    func report(_ error: Error, action: String, reconnect: Bool = true) {
        guard !isDisposed else { return }   // 已关闭：晚到的失败没人看
        let message = String(localized: "\(action)失败：\(FriendlyError.describe(error))",
                             comment: "操作失败提示：第一个是操作名（上传、重命名…），第二个是原因")
        guard reconnect, Self.isRecoverableTransportError(error) else {
            transientError = message
            return
        }
        // 先重连再提示：刷新成功会清空 `transientError`，提示要落在它之后。
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            guard !self.isDisposed else { return }
            self.transientError = message
        }
    }

    // MARK: - 上传覆盖检查

    /// 上传前的覆盖检查：列当前目录，返回 `urls` 中文件名已存在于远端的那些
    /// （即会被覆盖 / 截断的文件）。空数组 = 没有冲突，可直接上传。
    ///
    /// 单独一次 `list` 往返覆盖整批选择文件（不逐文件 stat），失败时（取不到列表）
    /// 返回空 —— 宁可正常走上传（带原有错误处理），也不因列目录失败误报覆盖、
    /// 拦住用户。视图据此决定是否弹覆盖确认（镜像删除确认）。
    func existingRemoteNames(forUploading urls: [URL]) async -> [String] {
        await existingRemoteNames(uploadFileNames: urls
            .filter { !$0.hasDirectoryPath }
            .map(\.lastPathComponent))
    }

    /// 同上，但入参是文件名（供测试 / 程序化上传）。
    func existingRemoteNames(uploadFileNames names: [String]) async -> [String] {
        guard let provider else { return [] }
        return await RemoteFileOperations.existingNames(names, in: currentPath, provider: provider)
    }

    // MARK: - 传输队列

    /// 入队多个本地文件上传（文件选择器 / 拖放）。目录跳过。
    /// 懒读：文件数据在槽位激活时再读，避免一次性把全部排队文件读入内存。
    func enqueueUploads(_ urls: [URL]) {
        let destinationDir = currentPath
        for url in urls where !url.hasDirectoryPath {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            let id = UUID()
            transfers.append(TransferItem(
                id: id, fileName: url.lastPathComponent, direction: .up,
                bytesDone: 0, bytesTotal: Int64(size ?? 0),
                speedBytesPerSec: 0, status: .queued))
            contexts[id] = TransferContext(source: .uploadURL(url), destinationDir: destinationDir)
            transferIndexByID[id] = transfers.count - 1
        }
        pumpQueue()
    }

    /// 入队一个内存数据上传（供测试 / 程序化上传）。
    func enqueueUpload(fileName: String, data: Data) {
        let id = UUID()
        transfers.append(TransferItem(
            id: id, fileName: fileName, direction: .up,
            bytesDone: 0, bytesTotal: Int64(data.count),
            speedBytesPerSec: 0, status: .queued))
        contexts[id] = TransferContext(source: .uploadData(data), destinationDir: currentPath)
        transferIndexByID[id] = transfers.count - 1
        pumpQueue()
    }

    /// 调度：上传和下载共用一个槽位池，避免多个下载绕过用户设置并放大内存/网络压力。
    private func pumpQueue() {
        let limit = fixedConcurrencyLimit ?? Self.maxConcurrentTransfers
        var active = transfers.filter { $0.status == .active }.count
        for idx in transfers.indices where active < limit {
            guard transfers[idx].status == .queued else { continue }
            startTransfer(id: transfers[idx].id)
            active += 1
        }
    }

    private func startTransfer(id: UUID) {
        guard let idx = transferIndex(id),
              let ctx = contexts[id], let provider else { return }
        transfers[idx].status = .active
        let source = ctx.source
        let task: Task<Void, Never>
        switch source {
        case .uploadURL, .uploadData:
            // 用入队时锚定的目录（而非 live currentPath），避免槽位激活时用户已切走目录。
            let remotePath = Self.join(ctx.destinationDir, transfers[idx].fileName)
            task = Task { [weak self] in
                await self?.runUpload(id: id, source: source,
                                      remotePath: remotePath, provider: provider)
            }
        case .download(let remotePath, let localURL):
            task = Task { [weak self] in
                await self?.runDownload(id: id, remotePath: remotePath,
                                        localURL: localURL, provider: provider)
            }
        }
        ctx.cancel = { task.cancel() }
    }

    private func runUpload(id: UUID, source: TransferContext.Source,
                           remotePath: String, provider: any SFTPProviding) async {
        do {
            switch source {
            case .uploadData(let data):
                try await provider.upload(data: data, toRemotePath: remotePath) { [weak self] p in
                    Task { @MainActor in self?.applyProgress(id: id, p) }
                }
            case .uploadURL(let url):
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                try await provider.upload(localURL: url, toRemotePath: remotePath) { [weak self] p in
                    Task { @MainActor in self?.applyProgress(id: id, p) }
                }
            case .download:
                return
            }
            finishTransfer(id, status: .done)
            await refresh()
        } catch is CancellationError {
            removeTransfer(id)
        } catch {
            finishTransfer(id, status: .failed)
        }
        contexts[id]?.cancel = nil
        pumpQueue()
    }

    /// 流式下载到本地 URL。登记为 .down 队列项并与上传共用并发预算。
    func downloadWithProgress(entry: RemoteEntry, to localURL: URL) async -> Bool {
        guard provider != nil, !entry.isDirectory else { return false }
        return await downloadWithProgress(
            remotePath: Self.join(currentPath, entry.name),
            fileName: entry.name,
            size: Self.int64Size(entry.size),
            to: localURL)
    }

    /// 按远端绝对路径下载（预览区 / 提示框的「下载…」用——手里只有路径，没有 `RemoteEntry`）。
    /// 与右键下载同一条传输队列，进度在状态栏传输 Dock 里。
    func downloadWithProgress(remotePath: String, size: Int64?, to localURL: URL) async -> Bool {
        guard provider != nil else { return false }
        var knownSize = size ?? 0
        if size == nil, let stat = try? await provider?.stat(remotePath) { knownSize = stat.size }
        return await downloadWithProgress(
            remotePath: remotePath,
            fileName: (remotePath as NSString).lastPathComponent,
            size: knownSize,
            to: localURL)
    }

    /// 下载入队的公共入口（macOS 拖出到 Finder 的文件承诺也走它，见 `FileBrowserModel+Desktop`）。
    func downloadWithProgress(remotePath: String,
                              fileName: String,
                              size: Int64,
                              to localURL: URL) async -> Bool {
        guard provider != nil, !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                transfers.append(TransferItem(
                    id: id, fileName: fileName, direction: .down,
                    bytesDone: 0, bytesTotal: size,
                    speedBytesPerSec: 0, status: .queued))
                let context = TransferContext(
                    source: .download(remotePath: remotePath, localURL: localURL),
                    destinationDir: currentPath)
                context.downloadCompletion = { continuation.resume(returning: $0) }
                contexts[id] = context
                transferIndexByID[id] = transfers.count - 1
                pumpQueue()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelTransfer(id) }
        }
    }

    private func runDownload(id: UUID, remotePath: String, localURL: URL,
                             provider: any SFTPProviding) async {
        do {
            try await provider.download(remotePath: remotePath, toLocalURL: localURL) { [weak self] p in
                Task { @MainActor in self?.applyProgress(id: id, p) }
            }
            finishTransfer(id, status: .done)
            completeDownload(id: id, success: true)
        } catch is CancellationError {
            completeDownload(id: id, success: false)
            removeTransfer(id)
        } catch {
            finishTransfer(id, status: .failed)
            contexts[id]?.cancel = nil
            transientError = String(localized: "下载失败：\(FriendlyError.describe(error))")
            completeDownload(id: id, success: false)
        }
        contexts[id]?.cancel = nil
        pumpQueue()
    }

    /// 取消一个传输。排队 / 完成 / 失败 → 直接移除该行；活动 → 取消其 Task（runner 捕获后移除）。
    func cancelTransfer(_ id: TransferItem.ID) {
        guard let item = transfers.first(where: { $0.id == id }) else { return }
        switch item.status {
        case .queued, .done, .failed:
            completeDownload(id: id, success: false)
            removeTransfer(id)
            pumpQueue()
        case .active: contexts[id]?.cancel?()
        }
    }

    /// 全部取消：清空所有进行中（排队 + 活动）的传输。
    func cancelAllActiveTransfers() {
        let ids = transfers.filter { $0.status == .queued || $0.status == .active }.map(\.id)
        for id in ids { cancelTransfer(id) }
    }

    /// 清除已完成 / 失败的传输行。
    func clearFinishedTransfers() {
        let ids = transfers.filter { $0.status == .done || $0.status == .failed }.map(\.id)
        for id in ids { contexts[id] = nil }
        transfers.removeAll { $0.status == .done || $0.status == .failed }
        rebuildTransferIndex()
    }

    /// 重试失败的上传（重新入队，复用原数据源）。下载不支持重试。
    func retryTransfer(_ id: TransferItem.ID) {
        guard let idx = transferIndex(id),
              transfers[idx].direction == .up, transfers[idx].status == .failed,
              contexts[id] != nil else { return }
        transfers[idx].status = .queued
        transfers[idx].bytesDone = 0
        transfers[idx].speedBytesPerSec = 0
        pumpQueue()
    }

    /// 结构变更后重建下标表。增删是低频操作，进度回调才是高频的。
    private func rebuildTransferIndex() {
        transferIndexByID.removeAll(keepingCapacity: true)
        transferIndexByID.reserveCapacity(transfers.count)
        for (index, item) in transfers.enumerated() { transferIndexByID[item.id] = index }
    }

    /// O(1) 查行；缓存过期（有人漏了 `rebuildTransferIndex`）时**自愈**：
    /// 校验缓存下标处真的是这一条，不是就退回线性扫描并把表修好。
    private func transferIndex(_ id: UUID) -> Int? {
        if let index = transferIndexByID[id], index < transfers.count,
           transfers[index].id == id {
            return index
        }
        guard let index = transfers.firstIndex(where: { $0.id == id }) else {
            transferIndexByID[id] = nil
            return nil
        }
        transferIndexByID[id] = index
        return index
    }

    private func updateTransfer(_ id: UUID, _ mutate: (inout TransferItem) -> Void) {
        guard let idx = transferIndex(id) else { return }
        mutate(&transfers[idx])
    }

    private func finishTransfer(_ id: UUID, status: TransferItem.Status) {
        updateTransfer(id) {
            $0.status = status
            $0.speedBytesPerSec = 0
            if status == .done { $0.bytesDone = $0.bytesTotal }
        }
    }

    private func removeTransfer(_ id: UUID) {
        transfers.removeAll { $0.id == id }
        contexts[id] = nil
        rebuildTransferIndex()
    }

    private func completeDownload(id: UUID, success: Bool) {
        let completion = contexts[id]?.downloadCompletion
        contexts[id]?.downloadCompletion = nil
        completion?(success)
    }

    /// 进度回调：更新已传字节，按 ~100ms 采样计算平滑速率。
    /// `internal`（非 `private`）以便单测直接验证终态守卫（迟到进度不回退已完成行）。
    func applyProgress(id: UUID, _ p: TransferProgress) {
        guard let idx = transferIndex(id) else { return }
        // 进度回调走独立 Task { @MainActor }，与 finishTransfer 之间无顺序保证。
        // 一旦传输已进入终态（.done/.failed），迟到的进度若继续写入就会回退
        // bytesDone（低于 total）/ 复活速率，把已完成的行打花。终态直接忽略。
        switch transfers[idx].status {
        case .done, .failed: return
        case .queued, .active: break
        }
        if let ctx = contexts[id] {
            let now = Date()
            if let last = ctx.lastSampleTime {
                let dt = now.timeIntervalSince(last)
                if dt >= Self.transferSpeedSampleInterval {
                    let inst = Double(p.bytesDone - ctx.lastSampleBytes) / dt
                    let prev = transfers[idx].speedBytesPerSec
                    transfers[idx].speedBytesPerSec = max(0, prev <= 0 ? inst : prev * 0.6 + inst * 0.4)
                    ctx.lastSampleTime = now
                    ctx.lastSampleBytes = p.bytesDone
                }
            } else {
                ctx.lastSampleTime = now
                ctx.lastSampleBytes = p.bytesDone
            }
        }
        transfers[idx].bytesDone = p.bytesDone
        if transfers[idx].bytesTotal == 0 { transfers[idx].bytesTotal = p.bytesTotal }
    }

    /// 关掉（窗口 / 标签关闭）。在途的建连落地后直接关掉、在途的加载与删除结果不再落地，
    /// 也不再对这台主机自动重连（看门狗 / 删除收尾的刷新都会因此 no-op）。
    /// 之后再 `connect(...)` 可以重新用。
    func dispose() {
        isDisposed = true
        hostKeyRelay.abandon()
        ownerEnrichmentTask?.cancel()
        ownerEnrichmentTask = nil
        loadGeneration &+= 1
        connectGeneration &+= 1
        settleLoading()
        deletionCancelled = true
        if state == .connecting { state = .idle }
        lastConnectionRequest = nil
        cancelAllActiveTransfers()
        closeCurrentProvider()
    }

    /// 清除一次性错误（绑定到错误 alert 的关闭）。
    func clearTransientError() {
        transientError = nil
    }

    /// 由视图层上报一次性错误（如本地保存下载内容失败），复用同一「操作失败」alert。
    /// `transientError` 是 `private(set)`，视图无法直接写，经此方法统一入口。
    func reportTransientError(_ message: String) {
        transientError = message
    }

    /// 服务器配置已删除等外部原因导致不可用时调用。
    /// 同时清掉重连请求：配置都没了，看门狗 / 刷新不应再对它发起重连
    /// （持有已删除的 SwiftData 模型还可能在访问属性时崩溃）。
    func markUnavailable(_ message: String) {
        state = .failed(message)
        lastConnectionRequest = nil
    }

    /// 转发到共享的 `RemotePath`（既有调用面保留）。
    nonisolated static func join(_ base: String, _ name: String) -> String {
        RemotePath.join(base, name)
    }

    nonisolated static func parent(of path: String) -> String {
        RemotePath.parent(of: path)
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        RemotePath.shellQuote(s)
    }

    /// 属主名补全（共享的 `RemoteFileOperations.resolveOwnerNames`）。
    private func resolveOwnerNames(for entries: [RemoteEntry],
                                   provider: any SFTPProviding,
                                   directoryPath: String) async -> [RemoteEntry] {
        await RemoteFileOperations.resolveOwnerNames(for: entries, in: directoryPath, provider: provider)
    }

    static func int64Size(_ size: UInt64?) -> Int64 {
        guard let size else { return 0 }
        return size > UInt64(Int64.max) ? Int64.max : Int64(size)
    }

    private func closeCurrentProvider() {
        let p = provider
        provider = nil
        Task { await p?.close() }
    }

    private static func isFailed(_ state: State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// 传输层失败（连接已死）→ 走自动重连；应用层错误（权限等）→ 原样报错。
    /// 判定委托给 `SSHTransportFailure`：按错误类型精确匹配 + 修正过词序的
    /// 字符串兜底（NIO 实际报 "I/O on closed channel"，旧词表只认
    /// "channel closed"，导致断网后刷新永远不重连）。
    static func isRecoverableTransportError(_ error: Error) -> Bool {
        SSHTransportFailure.isTransportFailure(error)
    }
}

// MARK: - 连接健康探测（ConnectionWatchdog）

extension FileBrowserModel: ConnectionHealthProbing {
    /// 系统唤醒 / 网络恢复后由 `ConnectionWatchdog` 调用。
    /// - 浏览中：探测底层传输是否还活着；判死时 provider 的底层通道已被
    ///   强制关闭，`refresh()` 会立刻拿到传输错误并自动重连、保留当前目录。
    /// - 失败态：直接试一次 `refresh()`（断网期间失败 → 网络恢复后侧栏自愈）。
    ///   `markUnavailable`（服务器配置已删除）/ `dispose` 会清掉 `lastConnectionRequest`，
    ///   不会对已删除 / 已关闭的主机发起重连。
    func probeConnectionHealth() async {
        switch state {
        case .browsing:
            guard let provider else { return }
            if await provider.verifyConnectionAlive() { return }
            guard provider === self.provider else { return }
            await refresh()
        case .failed:
            // 凭据 / 主机密钥 / 握手的问题不自动重试，等用户处理后自己点重试。
            guard lastConnectionRequest != nil, !failureNeedsUser else { return }
            await refresh()
        case .idle, .connecting:
            return
        }
    }
}
