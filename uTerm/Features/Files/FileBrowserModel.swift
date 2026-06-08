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

    /// 每个传输的不可展示状态：数据来源、取消句柄、测速采样点。
    /// MainActor 隔离，用 class 便于原地改可变字段。
    private final class TransferContext {
        enum Source { case uploadURL(URL); case uploadData(Data); case download }
        let source: Source
        /// 入队时捕获的目标目录（上传用）。槽位激活时机不确定，若上传时再读 live
        /// `currentPath` 会把排队中的上传落到当时正好停留的目录（用户已切走）；故在
        /// `enqueueUploads`/`enqueueUpload` 入队那一刻就锚定目录，传输/重试都用它。
        /// 下载项不用此字段（remotePath 在下载入口已锚定）。
        let destinationDir: String
        var cancel: (() -> Void)?
        var lastSampleTime: Date?
        var lastSampleBytes: Int64 = 0
        init(source: Source, destinationDir: String) {
            self.source = source
            self.destinationDir = destinationDir
        }
    }
    private var contexts: [UUID: TransferContext] = [:]

    /// 最大并发上传数（用户设置；默认 4，钳 1…64）。下载不计入此上限。
    static var maxConcurrentUploads: Int {
        let raw = UserDefaults.standard.object(forKey: "sftpMaxConcurrentTransfers") as? Int ?? 4
        return min(64, max(1, raw))
    }
    private static let transferSpeedSampleInterval: TimeInterval = 0.10

    private var restoredInitialPath: String?
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
        lastConnectionRequest = ConnectionRequest(profile: profile, modelContainer: modelContainer)
        await connectUsingLastRequest(force: false, initialPath: nil)
    }

    private func connectUsingLastRequest(force: Bool, initialPath: String?) async {
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
            await refresh(reconnectOnTransportFailure: false)
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
        await refresh(reconnectOnTransportFailure: true)
    }

    private func refresh(reconnectOnTransportFailure: Bool) async {
        guard let provider else {
            if reconnectOnTransportFailure {
                _ = await reconnectPreservingCurrentPath()
            }
            return
        }
        do {
            entries = try await provider.list(path: currentPath)
            state = .browsing
            transientError = nil
        } catch {
            if reconnectOnTransportFailure,
               Self.isRecoverableTransportError(error),
               await reconnectPreservingCurrentPath() {
                return
            }
            state = .failed("\(error)")
        }
    }

    private func reconnectPreservingCurrentPath() async -> Bool {
        guard lastConnectionRequest != nil else { return false }
        guard state != .connecting else { return false }
        await connectUsingLastRequest(force: true, initialPath: currentPath)
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
            entries = targetEntries
            state = .browsing
            transientError = nil
            return nil
        }
        let stat = try? await provider.stat(linkPath)
        return (linkPath, stat?.size, stat?.mtime)
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

    func makeDirectory(name: String) async {
        guard let provider else { return }
        do {
            try await provider.createDirectory(Self.join(currentPath, name))
            await refresh()
        } catch { transientError = "新建文件夹失败：\(error)" }
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
                guard let data = await self.downloadWithProgress(
                    remotePath: item.path,
                    fileName: item.name,
                    size: size) else {
                    completion(nil, false, NSError(
                        domain: "uTerm.RemoteFileDrag",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "下载失败"]))
                    return
                }
                do {
                    let url = try Self.writePromisedDownload(data: data, fileName: item.name)
                    progress.completedUnitCount = progress.totalUnitCount
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
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

    func delete(entry: RemoteEntry) async {
        guard let provider else { return }
        let path = Self.join(currentPath, entry.name)
        do {
            if entry.isDirectory {
                try await Self.deleteDirectoryRecursive(path, provider: provider)
            } else {
                try await provider.removeFile(path)
            }
            await refresh()
        } catch { transientError = "删除失败：\(error)" }
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

    /// 递归删目录：先删尽子项（子目录优先递归），最后 rmdir 自身。
    private static func deleteDirectoryRecursive(_ path: String,
                                                 provider: any SFTPProviding) async throws {
        let children = try await provider.list(path: path)
        for child in children {
            let childPath = Self.join(path, child.name)
            if child.isDirectory {
                try await deleteDirectoryRecursive(childPath, provider: provider)
            } else {
                try await provider.removeFile(childPath)
            }
        }
        try await provider.removeDirectory(path)
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
        pumpQueue()
    }

    /// 调度：把 .queued 上传提升为 .active，直到活动上传数达到上限。下载不计入。
    private func pumpQueue() {
        let limit = Self.maxConcurrentUploads
        var active = transfers.filter { $0.direction == .up && $0.status == .active }.count
        for idx in transfers.indices where active < limit {
            guard transfers[idx].direction == .up, transfers[idx].status == .queued else { continue }
            startUpload(id: transfers[idx].id)
            active += 1
        }
    }

    private func startUpload(id: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }),
              let ctx = contexts[id], let provider else { return }
        transfers[idx].status = .active
        // 用入队时锚定的目录（而非 live currentPath），避免槽位激活时用户已切走目录
        // 导致上传落错地方。
        let remotePath = Self.join(ctx.destinationDir, transfers[idx].fileName)
        let source = ctx.source
        let task = Task { [weak self] in
            await self?.runUpload(id: id, source: source, remotePath: remotePath, provider: provider)
        }
        ctx.cancel = { task.cancel() }
    }

    private func runUpload(id: UUID, source: TransferContext.Source,
                           remotePath: String, provider: any SFTPProviding) async {
        do {
            let data: Data
            switch source {
            case .uploadData(let d): data = d
            case .uploadURL(let url):
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
            case .download:
                return
            }
            try Task.checkCancellation()
            updateTransfer(id) { $0.bytesTotal = Int64(data.count) }
            try await provider.upload(data: data, toRemotePath: remotePath) { [weak self] p in
                Task { @MainActor in self?.applyProgress(id: id, p) }
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

    /// 下载到内存并返回（保存面板由视图层处理）。登记为 .down 传输项，可在 Dock 取消。
    func downloadWithProgress(entry: RemoteEntry) async -> Data? {
        guard let provider, !entry.isDirectory else { return nil }
        return await downloadWithProgress(
            remotePath: Self.join(currentPath, entry.name),
            fileName: entry.name,
            size: Self.int64Size(entry.size),
            provider: provider)
    }

    private func downloadWithProgress(remotePath: String,
                                      fileName: String,
                                      size: Int64) async -> Data? {
        guard let provider else { return nil }
        return await downloadWithProgress(
            remotePath: remotePath,
            fileName: fileName,
            size: size,
            provider: provider)
    }

    private func downloadWithProgress(remotePath: String,
                                      fileName: String,
                                      size: Int64,
                                      provider: any SFTPProviding) async -> Data? {
        let id = UUID()
        transfers.append(TransferItem(
            id: id, fileName: fileName, direction: .down,
            bytesDone: 0, bytesTotal: size,
            speedBytesPerSec: 0, status: .active))
        // 下载项不使用 destinationDir（remotePath 已锚定），传 currentPath 占位。
        contexts[id] = TransferContext(source: .download, destinationDir: currentPath)

        enum Outcome { case data(Data); case cancelled; case failed }
        let task = Task { () -> Outcome in
            do {
                let data = try await provider.download(remotePath: remotePath) { [weak self] p in
                    Task { @MainActor in self?.applyProgress(id: id, p) }
                }
                return .data(data)
            } catch is CancellationError { return .cancelled }
            catch { return .failed }
        }
        contexts[id]?.cancel = { task.cancel() }

        switch await task.value {
        case .data(let d):
            finishTransfer(id, status: .done); contexts[id]?.cancel = nil; return d
        case .cancelled:
            removeTransfer(id); return nil
        case .failed:
            finishTransfer(id, status: .failed); contexts[id]?.cancel = nil
            transientError = "下载失败"; return nil
        }
    }

    /// 取消一个传输。排队 / 完成 / 失败 → 直接移除该行；活动 → 取消其 Task（runner 捕获后移除）。
    func cancelTransfer(_ id: TransferItem.ID) {
        guard let item = transfers.first(where: { $0.id == id }) else { return }
        switch item.status {
        case .queued, .done, .failed: removeTransfer(id)
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
    }

    /// 重试失败的上传（重新入队，复用原数据源）。下载不支持重试。
    func retryTransfer(_ id: TransferItem.ID) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }),
              transfers[idx].direction == .up, transfers[idx].status == .failed,
              contexts[id] != nil else { return }
        transfers[idx].status = .queued
        transfers[idx].bytesDone = 0
        transfers[idx].speedBytesPerSec = 0
        pumpQueue()
    }

    private func updateTransfer(_ id: UUID, _ mutate: (inout TransferItem) -> Void) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
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
    }

    /// 进度回调：更新已传字节，按 ~100ms 采样计算平滑速率。
    /// `internal`（非 `private`）以便单测直接验证终态守卫（迟到进度不回退已完成行）。
    func applyProgress(id: UUID, _ p: TransferProgress) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
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

    /// 把路径包成单引号串供 shell（exec channel）安全使用：单引号内一切原样，
    /// 内嵌单引号用 `'\''` 收尾再续。供 `chmod -R` 等命令拼接，杜绝路径注入 / 空格问题。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    private static func writePromisedDownload(data: Data, fileName: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uterm-drag-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
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

    private static func isRecoverableTransportError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let message = "\(error) \(nsError.localizedDescription)".lowercased()
        return [
            "i/o channel close",
            "io channel close",
            "channel closed",
            "channel close",
            "connection reset",
            "connection closed",
            "connection lost",
            "broken pipe",
            "network is unreachable",
            "socket is not connected",
            "not connected",
        ].contains { message.contains($0) }
    }
}
