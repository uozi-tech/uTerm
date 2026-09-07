import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 文件浏览面板的状态机。导航/刷新/上传/下载经一个 `SFTPProviding`。
/// 生产用 `connect(...)` 建一个真实 `SFTPSession`；测试用 `init(testProvider:startPath:)`。
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

    /// 递归删除的进度快照。值类型，驱动侧栏 / 独立窗口顶部的删除进度条。
    ///
    /// 两段式：先深度优先枚举整棵子树（总数未知 → 不定态 + 已发现计数），
    /// 再逐项删（确定态 done/total）。删一个几千项的目录要几千次网络往返，
    /// 没有这条状态用户只能对着不动的列表干等。
    struct DeletionProgress: Equatable, Sendable {
        enum Phase: Sendable, Equatable { case counting, deleting }
        /// 被删的顶层项名（展示用）。
        let name: String
        var phase: Phase
        /// counting 阶段 = 已发现条目数；deleting 阶段 = 已删除条目数。
        var count: Int
        /// 待删总条目数（含目录自身）。counting 阶段为 nil。
        var total: Int?
        /// 用户已点取消，正在等当前这次网络往返返回。
        var isCancelling: Bool

        /// 确定态进度（0...1）。counting 阶段恒 0（视图此时用不定态条）。
        var fraction: Double {
            guard let total, total > 0 else { return 0 }
            return min(1, Double(count) / Double(total))
        }
    }

    private(set) var state: State = .idle
    private(set) var currentPath: String = "/"
    /// 是否正在切换目录（取新列表的网络往返进行中）。驱动视图加载态 + 再入守卫。
    private(set) var isNavigating = false
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
        static let showHidden    = "fileBrowser.showHidden"
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
    var showHidden: Bool = {
        UserDefaults.standard.object(forKey: PrefKey.showHidden) as? Bool ?? false
    }() {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: PrefKey.showHidden)
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
        let source = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }

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
        let indexed = source.enumerated().map { (idx: $0.offset, e: $0.element) }

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
    let remoteDragScopeID = UUID()
    private(set) var transientError: String?
    /// 传输队列（上传 + 下载）。仅 standalone SFTP 窗口渲染；侧边栏不写。
    private(set) var transfers: [TransferItem] = []
    /// 正在进行的递归删除；nil = 无。同一时刻只允许一个（见 `delete(entry:)` 的守卫）。
    private(set) var deletion: DeletionProgress?
    /// 取消旗标。`cancelDeletion()` 置位，删除循环在每次往返前检查。
    private var deletionCancelled = false
    /// 上一次把删除进度写回 `deletion` 的时刻（节流用）。
    private var lastDeletionPublish: Date?
    /// 删除进度写回的最小间隔：每删一项都写会让 SwiftUI 在大目录上每秒重渲染上千次。
    private static let deletionPublishInterval: TimeInterval = 0.10
    private static let ownerStatChunkSize = 80
    @ObservationIgnored private var ownerEnrichmentTask: Task<Void, Never>?
    private var ownerEnrichmentGeneration = 0

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
        let raw = UserDefaults.standard.object(forKey: "sftpMaxConcurrentTransfers") as? Int ?? 4
        return min(64, max(1, raw))
    }
    private static let transferSpeedSampleInterval: TimeInterval = 0.10

    private var restoredInitialPath: String?
    /// 是否成功浏览过至少一次。重连「保留当前目录」只在浏览过后才成立 ——
    /// 首次连接就失败时 `currentPath` 还是占位 "/"，强行保留会把重连后的
    /// 起始目录从用户家目录钉死到根目录。
    private var didEverBrowse = false
    private let sftpConnector: SFTPConnector
    @ObservationIgnored private var lastConnectionRequest: ConnectionRequest?

    private struct ConnectionRequest {
        let profile: ServerProfile
        let modelContainer: ModelContainer
    }

    /// 供 FilePreviewModel 共享同一 SFTP 通道（避免一个 workspace 开两个 channel）。
    /// nil 表示尚未 connect。Spec 2A §1.4。
    var sftpProvider: (any SFTPProviding)? { provider }
    var snapshotCurrentPath: String? {
        state == .browsing || restoredInitialPath != nil ? currentPath : nil
    }

    init(sftpConnector: @escaping SFTPConnector = FileBrowserModel.makeLiveSFTPProvider) {
        self.sftpConnector = sftpConnector
    }

    init(testProvider: any SFTPProviding, startPath: String) {
        self.sftpConnector = { _, _, _ in testProvider }
        self.provider = testProvider
        self.currentPath = startPath
        self.state = .browsing
    }

    func connect(profile: ServerProfile, modelContainer: ModelContainer) async {
        // 注册到看门狗：系统唤醒 / 网络恢复后主动探测，半死连接不再静默挂着。
        ConnectionWatchdog.shared.register(self)
        lastConnectionRequest = ConnectionRequest(profile: profile, modelContainer: modelContainer)
        await connectUsingLastRequest(force: false, initialPath: nil)
    }

    private func connectUsingLastRequest(force: Bool, initialPath: String?,
                                         waitForOwnerNames: Bool = true) async {
        guard let lastConnectionRequest else { return }
        // 视图层 `.task(id:)` 会在视图重建时重新触发 connect；已连接/连接中则视为
        // no-op，不撕掉活动 SFTP 会话。仅 .idle（首次）/ .failed（重试）才继续。
        guard force || state == .idle || Self.isFailed(state) else { return }
        if force {
            closeCurrentProvider()
        }
        state = .connecting
        // 任务被取消（如 sidebar 折叠 / 窗口关闭）时把 .connecting 重置回 .idle，
        // 否则下一次 connect 被 guard 直接跳过、永远停在 spinner 上（Fix #7）。
        defer {
            if Task.isCancelled, state == .connecting {
                state = .idle
            }
        }
        do {
            let session = try await sftpConnector(
                lastConnectionRequest.profile,
                lastConnectionRequest.modelContainer,
                hostKeyRelay)
            provider = session
            if let initialPath {
                currentPath = initialPath
            } else if let restoredInitialPath {
                currentPath = restoredInitialPath
                self.restoredInitialPath = nil
            } else {
                currentPath = (try? await session.realPath(".")) ?? "/"
            }
            await refresh(reconnectOnTransportFailure: false,
                          waitForOwnerNames: waitForOwnerNames)
        } catch {
            provider = nil
            state = .failed("\(error)")
        }
    }

    private static func makeLiveSFTPProvider(
        profile: ServerProfile,
        modelContainer: ModelContainer,
        hostKeyRelay: HostKeyChallengeRelay
    ) async throws -> any SFTPProviding {
        let keychain = KeychainStore()
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
        return try await SFTPSession(connected: connected)
    }

    func restoreCurrentPath(_ path: String) {
        guard !path.isEmpty else { return }
        currentPath = path
        restoredInitialPath = path
    }

    func refresh() async {
        await refresh(reconnectOnTransportFailure: true, waitForOwnerNames: true)
    }

    /// Agent 命令后的关键路径只等待目录列表。owner/group 的 exec 补全在后台继续，
    /// 让模型续轮不再被每 80 项一次的串行 shell 往返阻塞。
    func refreshListingAfterRemoteCommand() async {
        await refresh(reconnectOnTransportFailure: true, waitForOwnerNames: false)
    }

    private func refresh(reconnectOnTransportFailure: Bool,
                         waitForOwnerNames: Bool) async {
        guard let provider else {
            if reconnectOnTransportFailure {
                _ = await reconnectPreservingCurrentPath(waitForOwnerNames: waitForOwnerNames)
            }
            return
        }
        ownerEnrichmentTask?.cancel()
        ownerEnrichmentGeneration &+= 1
        let generation = ownerEnrichmentGeneration
        let directoryPath = currentPath
        do {
            let listed = try await provider.list(path: directoryPath)
            // 先发布 SFTP 原始 uid/gid；名字补全不是目录正确性的前置条件。
            entries = listed
            state = .browsing
            didEverBrowse = true
            transientError = nil
            if waitForOwnerNames {
                let enriched = await resolveOwnerNames(
                    for: listed,
                    provider: provider,
                    directoryPath: directoryPath)
                publishOwnerEnrichment(
                    enriched,
                    generation: generation,
                    directoryPath: directoryPath)
            } else {
                ownerEnrichmentTask = Task { [weak self, provider] in
                    guard let self else { return }
                    let enriched = await self.resolveOwnerNames(
                        for: listed,
                        provider: provider,
                        directoryPath: directoryPath)
                    guard !Task.isCancelled else { return }
                    self.publishOwnerEnrichment(
                        enriched,
                        generation: generation,
                        directoryPath: directoryPath)
                }
            }
        } catch {
            if reconnectOnTransportFailure,
               Self.isRecoverableTransportError(error),
               await reconnectPreservingCurrentPath(waitForOwnerNames: waitForOwnerNames) {
                return
            }
            state = .failed("\(error)")
        }
    }

    private func publishOwnerEnrichment(_ enriched: [RemoteEntry],
                                        generation: Int,
                                        directoryPath: String) {
        guard generation == ownerEnrichmentGeneration,
              currentPath == directoryPath else { return }
        entries = enriched
    }

    private func reconnectPreservingCurrentPath(waitForOwnerNames: Bool = true) async -> Bool {
        guard lastConnectionRequest != nil else { return false }
        guard state != .connecting else { return false }
        await connectUsingLastRequest(force: true,
                                      initialPath: didEverBrowse ? currentPath : nil,
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

    /// 直接跳到绝对路径（供面包屑 / 历史栈 / 前进后退 / `..` 驱动）。
    ///
    /// 再入守卫：一次目录切换的网络往返还没回来时，重复点击（典型是连点 `..`）
    /// 直接忽略 —— 否则第二次点会基于已经前移的 `currentPath` 再上一级，造成
    /// 越级。`isNavigating` 同时驱动视图加载态，让单击立刻有反馈、不被误以为没
    /// 生效（修复“点两次才返回 + 切目录闪烁”同源问题）。
    func navigate(toPath path: String) async {
        guard path != currentPath, !isNavigating else { return }
        isNavigating = true
        defer { isNavigating = false }
        currentPath = path
        await refresh()
    }

    /// 点击符号链接时懒解析：沿链接路径探测 —— `opendir` 跟随符号链接，能列出即
    /// 目标是目录，直接进入（复用探测到的列表，省一次往返）；否则当文件，`stat`
    /// 跟随链接取目标 size/mtime 返回，由调用方去打开（侧栏预览）/ 下载（独立窗口）。
    ///
    /// 返回 nil = 已进入目录（或非 symlink / 解析进行中）；非 nil = 目标是文件。
    /// 全程置 `isNavigating`，让侧栏加载层在解析往返期间盖住列表、不露旧目录。
    func resolveSymlinkForOpen(_ entry: RemoteEntry) async
        -> (path: String, size: Int64?, mtime: Date?)? {
        guard let provider, entry.isSymlink, !isNavigating else { return nil }
        isNavigating = true
        defer { isNavigating = false }
        let linkPath = Self.join(currentPath, entry.name)
        if let targetEntries = try? await provider.list(path: linkPath) {
            currentPath = linkPath
            entries = await resolveOwnerNames(for: targetEntries, provider: provider, directoryPath: linkPath)
            state = .browsing
            didEverBrowse = true
            transientError = nil
            return nil
        }
        let stat = try? await provider.stat(linkPath)
        return (linkPath, stat?.size, stat?.mtime)
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

    func makeDirectory(name: String) async {
        guard let provider else { return }
        do {
            try await provider.createDirectory(Self.join(currentPath, name))
            await refresh()
        } catch { transientError = "新建文件夹失败：\(error)" }
    }

    /// 在当前目录新建一个空文件（fail-if-exists，见 `SFTPProviding.createFile`）。
    func makeFile(name: String) async {
        guard let provider else { return }
        do {
            try await provider.createFile(Self.join(currentPath, name))
            await refresh()
        } catch { transientError = "新建文件失败：\(error)" }
    }

    func rename(entry: RemoteEntry, to newName: String) async {
        guard let provider else { return }
        let from = Self.join(currentPath, entry.name)
        let to = Self.join(currentPath, newName)
        do {
            try await provider.rename(from, to: to)
            await refresh()
        } catch { transientError = "重命名失败：\(error)" }
    }

    func remoteDragItem(for entry: RemoteEntry) -> RemoteFileDragItem {
        RemoteFileDragItem(
            scopeID: remoteDragScopeID,
            path: Self.join(currentPath, entry.name),
            name: entry.name,
            isDirectory: entry.isDirectory)
    }

    func remoteDragProvider(for entry: RemoteEntry) -> NSItemProvider {
        let item = remoteDragItem(for: entry)
        let provider = RemoteFileDragPayload.itemProvider(item: item)
        provider.suggestedName = entry.name

        guard !entry.isDirectory else { return provider }
        let size = Self.int64Size(entry.size)
        let type = Self.contentType(forFileName: entry.name)
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { [weak self] completion in
            let progress = Progress(totalUnitCount: max(1, size))
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(nil, false, CocoaError(.userCancelled))
                    return
                }
                let destinationURL: URL
                do {
                    destinationURL = try Self.promisedDownloadURL(fileName: item.name)
                } catch {
                    completion(nil, false, error)
                    return
                }
                guard await self.downloadWithProgress(
                    remotePath: item.path,
                    fileName: item.name,
                    size: size,
                    to: destinationURL) else {
                    completion(nil, false, NSError(
                        domain: "uTerm.RemoteFileDrag",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "下载失败"]))
                    return
                }
                progress.completedUnitCount = progress.totalUnitCount
                completion(destinationURL, false, nil)
            }
            return progress
        }
        return provider
    }

    @discardableResult
    func moveRemoteDragItem(_ item: RemoteFileDragItem, into target: RemoteEntry) async -> Bool {
        guard target.isDirectory else { return false }
        return await moveRemoteDragItem(item, intoDirectory: Self.join(currentPath, target.name))
    }

    @discardableResult
    func moveRemoteDragItem(_ item: RemoteFileDragItem,
                            intoDirectory targetDirectoryPath: String) async -> Bool {
        guard let provider, item.scopeID == remoteDragScopeID else { return false }
        let source = Self.normalizedRemotePath(item.path)
        let targetDirectory = Self.normalizedRemotePath(targetDirectoryPath)
        guard Self.canMoveRemoteDragItem(
            sourcePath: source,
            itemName: item.name,
            isDirectory: item.isDirectory,
            targetDirectoryPath: targetDirectory) else { return false }

        let destination = Self.join(targetDirectory, item.name)
        do {
            try await provider.rename(source, to: destination)
            await refresh()
            return true
        } catch {
            transientError = "移动失败：\(error)"
            return false
        }
    }

    /// 删除一个条目。文件 = 一次 `removeFile`；目录 = 枚举整棵子树后逐项删，
    /// 全程把进度写进 `deletion` 驱动进度条，并可中途取消（`cancelDeletion()`）。
    ///
    /// 无论成功 / 失败 / 取消，收尾都会 `refresh()` —— 失败或取消时远端多半已被删掉
    /// 一部分，列表必须跟着变。旧实现只在成功路径刷新，中途出错（典型：某个子项
    /// 无权限）就把已经不存在的项继续挂在侧栏上。错误消息在 refresh **之后**再置，
    /// 因为 refresh 成功会清空 `transientError`。
    func delete(entry: RemoteEntry) async {
        guard let provider else { return }
        // 同一条 SFTP 通道上一次只跑一个删除任务。静默吞掉第二次请求会让用户
        // 以为点击没生效（他刚在确认框上按了「删除」），故明确说一声。
        guard deletion == nil else {
            transientError = "正在删除「\(deletion?.name ?? "")」，请等它结束后再删下一项。"
            return
        }
        let path = Self.join(currentPath, entry.name)
        var failure: String?
        if entry.isDirectory {
            deletionCancelled = false
            lastDeletionPublish = nil
            deletion = DeletionProgress(name: entry.name, phase: .counting,
                                        count: 0, total: nil, isCancelling: false)
            do {
                try await deleteTree(at: path, provider: provider)
            } catch is DeletionCancelled {
                // 用户主动取消：不是错误，只把已删掉的部分刷出来。
            } catch {
                failure = "删除失败：\(FriendlyError.describe(error))"
            }
            deletion = nil
        } else {
            do {
                try await provider.removeFile(path)
            } catch {
                failure = "删除失败：\(FriendlyError.describe(error))"
            }
        }
        await refresh()
        if let failure { transientError = failure }
    }

    /// 请求中止正在进行的递归删除。已经删掉的部分不会回滚（SFTP 没有事务），
    /// 中止后照常刷新列表把剩下的显示出来。
    func cancelDeletion() {
        guard deletion != nil, !deletionCancelled else { return }
        deletionCancelled = true
        deletion?.isCancelling = true
    }

    /// 内部流程控制哨兵：用户取消删除。不上报给用户（不是错误）。
    private struct DeletionCancelled: Error {}

    /// 递归删目录：先一趟广度优先枚举拿到全部待删项（顺带得到总数 → 进度条能给
    /// 确定态），再先删文件、后按发现顺序**倒序**删目录。
    ///
    /// 倒序即可保证 rmdir 时目录一定已空：枚举是前序的（父一定先于子入列），
    /// 倒过来自然子先于父。这样整棵树只需一次 list 遍历，不必边删边重列。
    private func deleteTree(at root: String, provider: any SFTPProviding) async throws {
        // 前序：`directories[0]` 是 root，父恒排在子之前。
        var directories: [String] = [root]
        var files: [String] = []
        var cursor = 0
        while cursor < directories.count {
            try checkDeletionCancelled()
            let dir = directories[cursor]
            cursor += 1
            for child in try await provider.list(path: dir) {
                let childPath = Self.join(dir, child.name)
                // symlink 的 isDirectory 恒 false（列目录走 lstat）→ 只 unlink 链接
                // 本身，绝不跟随它进目标目录删别人的东西。
                if child.isDirectory {
                    directories.append(childPath)
                } else {
                    files.append(childPath)
                }
            }
            publishDeletionCount(files.count + directories.count, force: false)
        }

        try checkDeletionCancelled()
        deletion?.phase = .deleting
        deletion?.count = 0
        deletion?.total = files.count + directories.count
        lastDeletionPublish = nil

        var done = 0
        for file in files {
            try checkDeletionCancelled()
            try await provider.removeFile(file)
            done += 1
            publishDeletionCount(done, force: false)
        }
        for directory in directories.reversed() {
            try checkDeletionCancelled()
            try await provider.removeDirectory(directory)
            done += 1
            publishDeletionCount(done, force: false)
        }
        publishDeletionCount(done, force: true)
    }

    private func checkDeletionCancelled() throws {
        if deletionCancelled { throw DeletionCancelled() }
    }

    /// 把计数写回 `deletion`，按 `deletionPublishInterval` 节流。
    /// `force` 用于阶段收尾，保证最后一帧（100%）一定落到 UI 上。
    private func publishDeletionCount(_ count: Int, force: Bool) {
        let now = Date()
        if !force, let last = lastDeletionPublish,
           now.timeIntervalSince(last) < Self.deletionPublishInterval { return }
        lastDeletionPublish = now
        deletion?.count = count
    }

    /// 设置文件 / 文件夹权限（chmod）。`mode` 取低 9 位（`& 0o777`）。
    /// - 非递归（或文件）：走 SFTP `setstat`（`provider.setPermissions`）。
    /// - 递归（目录 + `recursive`）：开 exec channel 跑 `chmod -R <oct> <path>`，
    ///   一次性把整棵子树改掉（比逐项 setstat 可靠且快）。
    /// 完成后刷新列表；失败置 `transientError`。
    func setPermissions(entry: RemoteEntry, mode: UInt32, recursive: Bool) async {
        guard let provider else { return }
        let path = Self.join(currentPath, entry.name)
        let perm = mode & 0o777
        do {
            if recursive && entry.isDirectory {
                let oct = String(perm, radix: 8)
                _ = try await provider.exec("chmod -R \(oct) \(Self.shellQuote(path))")
            } else {
                try await provider.setPermissions(path: path, mode: perm)
            }
            await refresh()
        } catch { transientError = "权限设置失败：\(error)" }
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
        guard let provider, !names.isEmpty else { return [] }
        guard let listed = try? await provider.list(path: currentPath) else { return [] }
        let existing = Set(listed.map(\.name))
        return names.filter { existing.contains($0) }
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
        let limit = Self.maxConcurrentTransfers
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

    private func downloadWithProgress(remotePath: String,
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
            transientError = "下载失败：\(FriendlyError.describe(error))"
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

    func dispose() {
        hostKeyRelay.resolve(false)
        ownerEnrichmentTask?.cancel()
        ownerEnrichmentTask = nil
        ownerEnrichmentGeneration &+= 1
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

    static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        var comps = path.split(separator: "/", omittingEmptySubsequences: true)
        comps.removeLast()
        return comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
    }

    /// 把路径包成单引号串供 shell（exec channel）安全使用：单引号内一切原样，
    /// 内嵌单引号用 `'\''` 收尾再续。供 `chmod -R` 等命令拼接，杜绝路径注入 / 空格问题。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct OwnerStatRow {
        let uid: UInt32?
        let gid: UInt32?
        let ownerName: String?
        let groupName: String?
    }

    private func resolveOwnerNames(for entries: [RemoteEntry],
                                   provider: any SFTPProviding,
                                   directoryPath: String) async -> [RemoteEntry] {
        guard !entries.isEmpty else { return entries }
        var resolved = entries
        let indexedEntries = entries.enumerated()
            .filter { $0.element.uid != nil || $0.element.gid != nil }
            .map { (index: $0.offset, entry: $0.element) }
        guard !indexedEntries.isEmpty else { return entries }

        for start in stride(from: 0, to: indexedEntries.count, by: Self.ownerStatChunkSize) {
            let end = min(start + Self.ownerStatChunkSize, indexedEntries.count)
            let chunk = Array(indexedEntries[start..<end])
            let paths = chunk.map { Self.join(directoryPath, $0.entry.name) }
            let command = Self.ownerStatCommand(paths: paths)
            guard let output = try? await provider.exec(command) else { continue }
            let rows = Self.parseOwnerStatOutput(output)
            guard rows.count == chunk.count else { continue }

            for (indexed, row) in zip(chunk, rows) {
                resolved[indexed.index] = Self.entry(indexed.entry, applying: row)
            }
        }
        return resolved
    }

    private static func entry(_ entry: RemoteEntry, applying row: OwnerStatRow) -> RemoteEntry {
        let uid = row.uid ?? entry.uid
        let gid = row.gid ?? entry.gid
        let ownerName = row.uid == entry.uid || entry.uid == nil ? row.ownerName : nil
        let groupName = row.gid == entry.gid || entry.gid == nil ? row.groupName : nil
        return entry.withOwnerInfo(
            uid: uid,
            gid: gid,
            ownerName: ownerName,
            groupName: groupName)
    }

    private static func ownerStatCommand(paths: [String]) -> String {
        let quotedPaths = paths.map(shellQuote).joined(separator: " ")
        let gnuFormat = shellQuote("%u\t%g\t%U\t%G")
        let bsdFormat = shellQuote("%u\t%g\t%Su\t%Sg")
        return "(stat -c \(gnuFormat) -- \(quotedPaths) 2>/dev/null) || " +
            "stat -f \(bsdFormat) \(quotedPaths) 2>/dev/null"
    }

    private static func parseOwnerStatOutput(_ output: String) -> [OwnerStatRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4 else { return nil }
            let uid = UInt32(fields[0])
            let gid = UInt32(fields[1])
            return OwnerStatRow(
                uid: uid,
                gid: gid,
                ownerName: normalizedOwnerName(fields[2], numericID: uid),
                groupName: normalizedOwnerName(fields[3], numericID: gid))
        }
    }

    private static func normalizedOwnerName(_ raw: Substring, numericID: UInt32?) -> String? {
        let value = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "UNKNOWN", value != "?" else { return nil }
        if let numericID, value == String(numericID) { return nil }
        return value
    }

    private static func canMoveRemoteDragItem(sourcePath: String,
                                              itemName: String,
                                              isDirectory: Bool,
                                              targetDirectoryPath: String) -> Bool {
        guard !itemName.isEmpty, sourcePath != "/" else { return false }
        let destination = join(targetDirectoryPath, itemName)
        guard destination != sourcePath else { return false }
        if isDirectory {
            guard targetDirectoryPath != sourcePath else { return false }
            guard !targetDirectoryPath.hasPrefix(sourcePath + "/") else { return false }
        }
        return true
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        var value = path.hasPrefix("/") ? path : "/" + path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func int64Size(_ size: UInt64?) -> Int64 {
        guard let size else { return 0 }
        return size > UInt64(Int64.max) ? Int64.max : Int64(size)
    }

    private static func contentType(forFileName fileName: String) -> UTType {
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }

    private static func promisedDownloadURL(fileName: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uterm-drag-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(fileName, isDirectory: false)
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
    private static func isRecoverableTransportError(_ error: Error) -> Bool {
        SSHTransportFailure.isTransportFailure(error)
    }
}

// MARK: - 连接健康探测（ConnectionWatchdog）

extension FileBrowserModel: ConnectionHealthProbing {
    /// 系统唤醒 / 网络恢复后由 `ConnectionWatchdog` 调用。
    /// - 浏览中：探测底层传输是否还活着；判死时 provider 的底层通道已被
    ///   强制关闭，`refresh()` 会立刻拿到传输错误并自动重连、保留当前目录。
    /// - 失败态：直接试一次 `refresh()`（断网期间失败 → 网络恢复后侧栏自愈）。
    ///   `markUnavailable`（服务器配置已删除）会清掉 `lastConnectionRequest`，
    ///   不会对已删除的服务器发起重连。
    func probeConnectionHealth() async {
        switch state {
        case .browsing:
            guard let provider else { return }
            if await provider.verifyConnectionAlive() { return }
            await refresh()
        case .failed:
            guard lastConnectionRequest != nil else { return }
            await refresh()
        case .idle, .connecting:
            return
        }
    }
}
