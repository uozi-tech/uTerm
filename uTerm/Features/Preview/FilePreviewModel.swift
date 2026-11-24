import UPaneGroups
import UDesignKit
import SwiftUI
import AppKit

/// 编辑器键盘焦点请求。用户**主动**打开文件 / 点击标签时代数 +1，
/// `CodeEditorView` 消费后把窗口第一响应者交给文本视图，让 ⌘A/⌘C 等编辑菜单
/// 快捷键立即作用于文件内容（而不是停留在文件树 / 终端等旧焦点上）。
/// 会话恢复（`restoreOpenFiles`）不发请求 —— 避免开窗时抢终端焦点。
nonisolated struct EditorFocusRequest: Equatable, Sendable {
    let generation: Int
    let bufferID: UUID
}

/// 有界的 markdown 图片缓存。按插入顺序（FIFO）淘汰，受单图上限、总字节上限
/// 和条目数上限三重约束，防止引用大量/超大远程图片时撑爆内存。
/// 纯值类型，便于单测淘汰逻辑（网络/SFTP 路径本身不可单测）。
nonisolated struct MarkdownImageCache: Sendable {
    /// 单张图片允许的最大体积；超过则拒绝缓存与预览。
    static let perImageByteCap = 8 * 1024 * 1024
    /// 缓存总字节上限。
    static let totalByteCap = 64 * 1024 * 1024
    /// 缓存条目数上限（即便单图都很小，也防止条目无限增长）。
    static let maxEntryCount = 64

    private let perImageByteCap: Int
    private let totalByteCap: Int
    private let maxEntryCount: Int

    /// 插入顺序（最旧在前），用于 FIFO 淘汰。
    private var order: [RemoteNameKey] = []
    private var storage: [RemoteNameKey: Data] = [:]
    private(set) var totalBytes = 0

    init(perImageByteCap: Int = MarkdownImageCache.perImageByteCap,
         totalByteCap: Int = MarkdownImageCache.totalByteCap,
         maxEntryCount: Int = MarkdownImageCache.maxEntryCount) {
        self.perImageByteCap = perImageByteCap
        self.totalByteCap = totalByteCap
        self.maxEntryCount = maxEntryCount
    }

    var count: Int { storage.count }

    subscript(key: RemoteNameKey) -> Data? { storage[key] }

    /// 插入一条。超出单图上限的不缓存；插入后按总字节/条目数上限从最旧开始淘汰。
    /// 返回是否成功缓存（超单图上限时为 false）。
    @discardableResult
    mutating func insert(_ data: Data, forKey key: RemoteNameKey) -> Bool {
        guard data.count <= perImageByteCap else { return false }

        if let existing = storage[key] {
            totalBytes -= existing.count
            order.removeAll { $0 == key }
        }
        storage[key] = data
        order.append(key)
        totalBytes += data.count

        evictIfNeeded()
        return true
    }

    mutating func removeAll() {
        order.removeAll()
        storage.removeAll()
        totalBytes = 0
    }

    private mutating func evictIfNeeded() {
        while !order.isEmpty,
              (totalBytes > totalByteCap || storage.count > maxEntryCount) {
            let oldest = order.removeFirst()
            if let removed = storage.removeValue(forKey: oldest) {
                totalBytes -= removed.count
            }
        }
    }
}

@MainActor
@Observable
final class FilePreviewModel {
    private static let maximumPreviewBytes: Int64 = 50 * 1024 * 1024

    /// 打开着的**文档**集合。注意这不是标签顺序 —— 标签（顺序、分组、前台）住在
    /// `panes` 里，同一个文档可以同时有多个标签落在不同的组。这里只是「谁被打开着」
    /// 的去重集合，供刷新循环与按 id 查找用；最后一个引用它的标签被关掉时移除。
    private(set) var buffers: [FileBuffer] = []

    /// 预览区的编辑组树（VS Code 模型：分屏的叶子是组，组里一排标签）。
    /// 载荷直接就是 `FileBuffer` —— 面板因此不必再在自己的 body 里扫 `buffers`
    /// 数组（改造前 `buffer(forPanel:)` 就是那么干的，保活之后会让每个面板都挂在
    /// 这个 @Observable 数组上，开/关任意标签全体重算）。
    let panes: UPaneGroupsModel<FileBuffer>

    private(set) var recents: [RecentFileEntry] = []
    /// 最近一次编辑器焦点请求（语义见 `EditorFocusRequest`）。
    private(set) var editorFocusRequest: EditorFocusRequest?

    enum SaveOutcome {
        case saved
        case conflict(remoteMtime: Date)
        case failed(String)
        case noop
    }

    enum PreviewDownloadError: LocalizedError {
        case providerUnavailable
        case missingBuffer
        case invalidMarkdownImageSource
        case unsupportedMarkdownImageSource(String)
        case markdownImageTooLarge(bytes: Int)
        case markdownImageNotAFile
        case tooManyMarkdownImages

        var errorDescription: String? {
            switch self {
            case .providerUnavailable:
                return String(localized: "SFTP 尚未连接")
            case .missingBuffer:
                return String(localized: "文件缓冲区不存在")
            case .invalidMarkdownImageSource:
                return String(localized: "图片地址为空或无效")
            case .unsupportedMarkdownImageSource(let source):
                return String(localized: "为保护本机网络，Markdown 只预览同一 SFTP 主机上的图片：\(source)")
            case .markdownImageTooLarge(let bytes):
                let cap = UFormat.bytes(MarkdownImageCache.perImageByteCap)
                return String(localized: "图片超过 \(cap)（实际约 \(UFormat.bytes(bytes))），已跳过预览")
            case .markdownImageNotAFile:
                return String(localized: "不是普通文件，不预览")
            case .tooManyMarkdownImages:
                return String(localized: "这个文档引用的图片太多，只预览前 \(MarkdownImageCache.maxEntryCount) 张")
            }
        }
    }

    private let recentsStore: RecentFilesStore
    /// 工厂：每次取一个最新的 SFTP provider（由 WorkspaceModel 注入；
    /// 共享 FileBrowserModel 的 SFTP 会话）。
    private let sftpProvider: () -> (any SFTPProviding)?
    private var markdownImageCache = MarkdownImageCache()
    /// 每个文档读过哪些图（路径）：一篇文档最多读 `MarkdownImageCache.maxEntryCount` 张，免得一篇引用上千张图的文档
    /// 一下子开出上千次 SFTP 读。重读文档时清掉。
    private var markdownImageRequests: [UUID: Set<RemoteNameKey>] = [:]
    /// 不在预览区里的文档：终端区里由终端打开的文件标签（`openDetached`）。各自带着发起那个终端所连主机的 SFTP
    /// （终端窗口的标签可连不同主机，工作区里也可能不是侧栏那台），按文档 id 记；标签关掉时 `releaseDetached`。
    private var detached: [UUID: (buffer: FileBuffer, provider: any SFTPProviding)] = [:]
    private var remoteCommandRefreshGeneration = 0

    /// 自动保存开着没有（设置 › 通用 › 文件，默认开）。测试里换掉，免得读写正式版的偏好。
    var isAutosaveEnabled: () -> Bool = { FilePreviewModel.autosavePreference() }
    /// 最后一次编辑之后停多久写回主机。
    var autosaveDelay: Duration = .seconds(1)
    private var autosaveTasks: [UUID: Task<Void, Never>] = [:]

    /// 还在的模型（每个工作区 / 终端窗口一个）：退出 App 时一起存（`EditorCloseGuard.shouldTerminate`）。
    private static let live = NSHashTable<FilePreviewModel>.weakObjects()
    static var allLive: [FilePreviewModel] { live.allObjects }

    nonisolated static func autosavePreference(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKey.editorAutoSave) as? Bool ?? true
    }

    init(recentsStore: RecentFilesStore,
         sftpProvider: @escaping () -> (any SFTPProviding)?) {
        self.recentsStore = recentsStore
        self.sftpProvider = sftpProvider
        // 保活取默认的 .allTabs：面板内容是 CodeEditTextView 的 NSView 这类静止时
        // 不干活的编辑器（与 uTable 的数据网格同款），拍平挂载成立 —— 切标签是纯
        // 透明度翻转，不重建。（终端区是另一回事，隐藏的终端仍在全速重绘。）
        self.panes = UPaneGroupsModel<FileBuffer>(policy: UPaneGroupsPolicy(
            splitButtonMaxGroups: nil,      // 改造前预览区分屏就不限组数
            collapsesEmptyGroups: true,
            allowsLastGroupEmpty: true,     // 最后一个组空着显示「最近打开」
            releasesHiddenEditorFocusOnTabSwitch: true,
            keepAlive: .allTabs))
        self.recents = recentsStore.load()
        Self.live.add(self)

        // 关标签 → 引用计数 → 没人再引用才释放文档。改造前是「关 buffer」，于是
        // 同一个文件被两个面板引用时必然出岔子（见 reconcilePanelsAfterClosingBuffer）。
        panes.onTabRemoved = { [weak self] removed, remaining in
            self?.releaseBufferIfUnreferenced(removed.payload, remaining: remaining)
        }
        // 组里唯一的标签被拖到本组边缘：克隆一个指向**同一个文档**的新标签。
        // 这正是改造前 `dropBuffer` 的语义（新面板复用同一个 buffer）。
        panes.cloneTab = { tab in UPaneTab(payload: tab.payload) }
        // 分屏按钮开**空**组（空态显示「最近打开」），不克隆当前文件。
        panes.makeTabForNewGroup = { nil }
    }

    /// 活动组的前台标签所对应的文档。
    var activeBuffer: FileBuffer? { panes.activeTab?.payload }
    /// 兼容旧调用点（⌘W 的 `CloseIntent`、⌘S 的回落目标）。只读。
    var activeBufferID: UUID? { panes.activeTab?.payload.id }
    /// 活动组前台标签的 id（⌘W 的关闭目标）。
    var activeTabID: UUID? { panes.activeTab?.id }
    /// 标签在整个预览区的显示顺序（深度优先：先按分屏树走组，组内从左到右）。
    var tabIDsInDisplayOrder: [UUID] { panes.allTabs.map(\.id) }
    /// 同上，取每个标签背后的文档 id（测试与调试用）。
    var tabBufferIDsInDisplayOrder: [UUID] { panes.allTabs.map(\.payload.id) }

    /// 一次拖拽载荷里的 id 到底指谁。
    ///
    /// 预览标签的拖拽类型仍是 `.utermFileBufferID`（终端区的窗格投放代理认这个类型，
    /// 「预览标签拖进终端窗格」这条既有路径不能丢），但组件写进 `NSItemProvider`
    /// 的是**标签** id 而不是 buffer id —— 所以这里两种都认。
    func buffer(forDragPayloadID id: UUID) -> FileBuffer? {
        if let tab = panes.tab(id) { return tab.payload }
        return buffers.first { $0.id == id }
    }

    /// 关一个标签之前要知道的两件事：它背后的文档，以及它是不是**最后一个**引用该
    /// 文档的标签 —— 只有那时关掉才会丢内容，脏文件确认也只在那时才该弹。
    func closeContext(forTab tabID: UUID) -> (buffer: FileBuffer, isLastReference: Bool)? {
        guard let tab = panes.tab(tabID) else { return nil }
        let references = panes.allTabs.reduce(0) { $0 + ($1.payload === tab.payload ? 1 : 0) }
        return (tab.payload, references <= 1)
    }

    /// 切到某个标签（点 chip 之外的入口用；chip 自己由组件处理）。
    func selectTab(_ tabID: UUID, focusEditor: Bool = true) {
        guard let at = panes.locateTab(tabID),
              let buffer = panes.groups[at.groupID]?.tabs[at.index].payload else { return }
        panes.activateTab(groupID: at.groupID, index: at.index)
        if focusEditor { requestEditorFocus(buffer.id) }
    }

    /// 用户主动打开 / 切换文件 → 请求把键盘焦点交给对应编辑器。
    private func requestEditorFocus(_ bufferID: UUID) {
        let next = (editorFocusRequest?.generation ?? 0) + 1
        editorFocusRequest = EditorFocusRequest(generation: next, bufferID: bufferID)
    }

    /// SFTPSidebar 文件 tap → 通知 → 调用。`asPreview` = 以预览（临时）tab 打开：
    /// 顶替现有预览 tab 而不是新增；永久打开（双击）同一路径会把预览 tab 转正。
    /// `focusEditor` 为 false 时不把键盘焦点交给编辑器（终端里的程序请求预览：用户还在终端里打字）。
    func open(path: String, fileSize: Int64?, mtime: Date?, asPreview: Bool = false,
              focusEditor: Bool = true) async {
        // 已打开（在任何一个组里）则只切过去；永久打开命中预览标签时转正。
        if let existing = panes.allTabs.first(where: { $0.payload.remotePath.remoteKey == path.remoteKey }) {
            selectTab(existing.id, focusEditor: focusEditor)
            if !asPreview { panes.promoteTransient(existing.id) }
            return
        }

        let buf = makeBuffer(remotePath: path, byteSize: fileSize, mtime: mtime)
        buffers.append(buf)
        // asPreview 时组件会顶替**活动组**里已有的那个 transient 标签，位置不动。
        // 脏的预览标签在变脏那一刻就已经转正（见 FileBuffer.onBecameDirty），
        // 所以这里不会顶掉用户改过的内容。
        //
        // 被顶替的那个标签是**就地覆盖**的，组件不会为它发 `onTabRemoved`
        // （`openTab` 里 `group.tabs[slot] = tab`），所以它背后的文档得在这里自己
        // 收 —— 否则每顶替一次就漏一个 buffer。
        let displaced = asPreview
            ? panes.activeGroup?.tabs.first(where: { $0.isTransient })?.payload
            : nil
        panes.openTab({ UPaneTab(payload: buf) }, asTransient: asPreview)
        if let displaced {
            releaseBufferIfUnreferenced(displaced, remaining: panes.allTabs)
        }
        if focusEditor { requestEditorFocus(buf.id) }

        // 类型检查在大小之前：归档/二进制不该因为「碰巧小于 50 MB」就去下载。
        if let reason = Self.unsupportedPreviewReason(forPath: path) {
            buf.state = .failed(reason)
            return
        }

        // 大小检查
        if let fileSize, fileSize > Self.maximumPreviewBytes {
            buf.state = .failed(String(localized: "文件超过 50 MB，用本机应用打开"))
            return
        }

        await load(buf, failIfProviderMissing: true)
    }

    /// 终端里的程序请在预览区显示一个文件（`TerminalFilePreview`，Claude Code 写完文档 / 图片之后）。
    ///
    /// 没打开过：以预览（临时）标签打开，顶替上一个预览标签。已经打开：切过去并重读——程序刚改过它；用户改了没存
    /// （脏）或正在存的不重读，免得盖掉用户的编辑。两种都不抢键盘焦点。
    func reveal(path: String) async {
        guard let existing = panes.allTabs.first(where: { $0.payload.remotePath.remoteKey == path.remoteKey }) else {
            await open(path: path, fileSize: nil, mtime: nil, asPreview: true, focusEditor: false)
            return
        }
        selectTab(existing.id, focusEditor: false)
        let buf = existing.payload
        guard !buf.isDirty else { return }
        if case .saving = buf.state { return }
        // Markdown 里引用的同目录图片多半也是刚生成的。
        markdownImageCache.removeAll()
        buf.mtimeWhenLoaded = nil
        await load(buf, failIfProviderMissing: true)
    }

    // MARK: 游离文档（终端区里由终端打开的文件）

    /// 新建一个不在预览区里的文档并加载：读写都走 `provider`（发起那个终端所连的主机）。由工作区把它放进终端区。
    func openDetached(path: String, provider: any SFTPProviding) async -> FileBuffer {
        let buf = makeBuffer(remotePath: path, byteSize: nil, mtime: nil)
        detached[buf.id] = (buf, provider)
        await load(buf, failIfProviderMissing: true)
        return buf
    }

    /// 程序刚改过它：重读。用户改了没存（脏）或正在存的不重读。
    func reloadDetached(_ buf: FileBuffer) async {
        guard detached[buf.id] != nil, !buf.isDirty else { return }
        if case .saving = buf.state { return }
        markdownImageCache.removeAll()
        buf.mtimeWhenLoaded = nil
        await load(buf, failIfProviderMissing: true)
    }

    /// 最后一个引用它的标签关掉了。
    func releaseDetached(_ id: UUID) {
        detached[id]?.buffer.onBecameDirty = nil
        cancelAutosave(id)
        detached[id] = nil
        markdownImageRequests[id] = nil
    }

    func isDetached(_ id: UUID) -> Bool { detached[id] != nil }

    /// 这个文档开在本窗口里（预览区或终端区）。⌘S 的通知会广播到所有窗口，只有它的主人处理。
    func owns(_ id: UUID) -> Bool { knownBuffer(id) != nil }

    fileprivate func knownBufferForSave(_ id: UUID) -> FileBuffer? { knownBuffer(id) }

    private func knownBuffer(_ id: UUID) -> FileBuffer? {
        buffers.first { $0.id == id } ?? detached[id]?.buffer
    }

    private func provider(for buf: FileBuffer) -> (any SFTPProviding)? {
        detached[buf.id]?.provider ?? sftpProvider()
    }

    /// 该标签是否处于「预览（临时）」状态（斜体、会被下一次单击顶替）。
    /// 编辑中（脏）的标签在变脏那一刻已经转正，所以这里恒为 false。
    func isTransientTab(_ tabID: UUID) -> Bool { panes.tab(tabID)?.isTransient ?? false }

    /// 把预览标签转正（双击 / 右键「保留标签页」/ 永久打开同一文件 / 保存时调用）。
    func keepTab(_ tabID: UUID) { panes.promoteTransient(tabID) }

    /// 把指向某文档的所有预览标签一起转正（保存 / 变脏走这条 —— 它们只认得 buffer）。
    private func promoteTransientTabs(for buffer: FileBuffer) {
        for tab in panes.allTabs where tab.payload === buffer && tab.isTransient {
            panes.promoteTransient(tab.id)
        }
    }

    /// 新建一个文档并接上「变脏即转正」的钩子。所有 buffer 都必须走这里。
    private func makeBuffer(remotePath: String, byteSize: Int64?, mtime: Date?) -> FileBuffer {
        let buf = FileBuffer(remotePath: remotePath,
                             kind: LanguageDetector.kind(forPath: remotePath))
        buf.byteSize = byteSize
        buf.mtimeWhenLoaded = mtime
        buf.onBecameDirty = { [weak self] buffer in
            self?.promoteTransientTabs(for: buffer)
        }
        buf.onEdited = { [weak self] buffer in
            self?.scheduleAutosave(buffer)
        }
        return buf
    }

    /// `onTabRemoved` 钩子：没有别的标签再引用这个文档时才真的释放它。
    /// 改造前是「关标签 = 关 buffer」，于是同一个文件被两个面板引用时必然出岔子。
    private func releaseBufferIfUnreferenced(_ buffer: FileBuffer,
                                             remaining: [UPaneTab<FileBuffer>]) {
        guard !remaining.contains(where: { $0.payload === buffer }) else { return }
        buffer.onBecameDirty = nil
        cancelAutosave(buffer.id)
        buffers.removeAll { $0 === buffer }
        markdownImageRequests[buffer.id] = nil
    }

    /// 恢复上次打开的文件。
    ///
    /// 快照格式一个字节都没变（`openFiles` 平铺列表 + `activeFileIndex`）：改造前
    /// 面板树本来就不持久化，恢复时 `rebuildSinglePanelForActiveBuffer()` 只重建
    /// 一个面板。所以迁到组模型是**恒等映射** —— 全部标签塞进唯一一个组，
    /// `activeFileIndex` 成为该组的 `activeIndex`，既不丢东西也不需要迁移代码。
    func restoreOpenFiles(_ snapshots: [OpenFileSnapshot]?, activeIndex: Int?) {
        for buf in buffers { buf.onBecameDirty = nil; cancelAutosave(buf.id) }
        buffers.removeAll()
        let snapshots = snapshots ?? []
        let restored = UPaneGroupsSnapshot<OpenFileSnapshot>(
            root: .leaf(groupIndex: 0),
            groups: [.init(tabs: snapshots, activeIndex: activeIndex ?? 0)],
            activeGroupIndex: 0)
        panes.restore(restored) { [weak self] snapshot in
            guard let self else { return nil }
            let buf = self.makeBuffer(remotePath: snapshot.remotePath,
                                      byteSize: snapshot.byteSize,
                                      mtime: snapshot.mtimeWhenLoaded)
            self.buffers.append(buf)
            return UPaneTab(payload: buf)   // 恢复的标签一律永久，不是预览标签
        }
    }

    /// 存盘用的打开文件清单。按**标签显示顺序**（深度优先）平铺，同一个文档被多个
    /// 标签引用时只写一条 —— 与改造前的格式逐字相同。
    func openFileSnapshots() -> ([OpenFileSnapshot], Int?) {
        var activeIndex: Int?
        var indexByBuffer: [ObjectIdentifier: Int] = [:]
        var snapshots: [OpenFileSnapshot] = []
        let activeTabID = panes.activeTab?.id
        for tab in panes.allTabs {
            let key = ObjectIdentifier(tab.payload)
            let index: Int
            if let existing = indexByBuffer[key] {
                index = existing
            } else {
                index = snapshots.count
                indexByBuffer[key] = index
                snapshots.append(OpenFileSnapshot(
                    remotePath: tab.payload.remotePath,
                    byteSize: tab.payload.byteSize,
                    mtimeWhenLoaded: tab.payload.mtimeWhenLoaded))
            }
            if tab.id == activeTabID { activeIndex = index }
        }
        return (snapshots, activeIndex)
    }

    func loadRestoredBuffersIfNeeded() async {
        for buf in buffers where buf.state == .loading {
            await load(buf, failIfProviderMissing: false)
        }
    }

    /// Agent 的远端命令结束后同步已打开文件。
    ///
    /// 当前可见文件始终重读，避免远端文件系统只有秒级 mtime、且内容等长改写时
    /// size/mtime 都未变化而继续展示旧内容；其余标签先比较元信息，减少不必要下载。
    /// 本地脏 buffer 与正在保存的 buffer 必须跳过，不能让后台刷新覆盖用户输入。
    func refreshAfterRemoteCommand() async {
        let generation = await refreshVisibleAfterRemoteCommand()
        await refreshInactiveAfterRemoteCommand(generation: generation)
    }

    /// Agent 续轮的关键刷新：只等待当前可见 buffer。返回 generation 给后台标签刷新，
    /// 新命令到来时旧 generation 的结果不会覆盖更新后的内容。
    @discardableResult
    func refreshVisibleAfterRemoteCommand() async -> Int {
        remoteCommandRefreshGeneration &+= 1
        let generation = remoteCommandRefreshGeneration
        let visibleID = activeBufferID
        let visible = buffers.filter { $0.id == visibleID }
        await refreshBuffersAfterRemoteCommand(
            visible,
            visibleID: visibleID,
            generation: generation)
        return generation
    }

    /// 非活动标签仅在元信息变化时重读，由 WorkspaceModel 放到非结构化后台任务。
    func refreshInactiveAfterRemoteCommand(generation: Int) async {
        guard generation == remoteCommandRefreshGeneration else { return }
        let visibleID = activeBufferID
        let inactive = buffers.filter { $0.id != visibleID }
        await refreshBuffersAfterRemoteCommand(
            inactive,
            visibleID: visibleID,
            generation: generation)
    }

    private func refreshBuffersAfterRemoteCommand(_ candidates: [FileBuffer],
                                                  visibleID: UUID?,
                                                  generation: Int) async {
        guard generation == remoteCommandRefreshGeneration,
              let sftp = sftpProvider() else { return }
        var didReload = false

        for buf in candidates {
            guard generation == remoteCommandRefreshGeneration,
                  !Task.isCancelled else { return }
            guard !buf.isDirty else { continue }
            if case .saving = buf.state { continue }
            guard Self.unsupportedPreviewReason(forPath: buf.remotePath) == nil else { continue }

            do {
                let remote = try await sftp.stat(buf.remotePath)
                guard generation == remoteCommandRefreshGeneration else { return }
                let metadataChanged = buf.byteSize != remote.size
                    || buf.mtimeWhenLoaded != remote.mtime
                guard buf.id == visibleID || metadataChanged else { continue }

                guard remote.size <= Self.maximumPreviewBytes else {
                    buf.byteSize = remote.size
                    buf.mtimeWhenLoaded = remote.mtime
                    buf.state = .failed(String(localized: "文件超过 50 MB，用本机应用打开"))
                    continue
                }

                let data = try await sftp.download(
                    remotePath: buf.remotePath,
                    maximumBytes: Int(Self.maximumPreviewBytes))

                // 下载期间用户可能已经开始输入或关闭标签；完成后再次确认，避免异步
                // 回包覆盖新编辑，也避免继续修改已从模型移除的 buffer 引用。
                guard generation == remoteCommandRefreshGeneration,
                      buffers.contains(where: { $0.id == buf.id }),
                      !buf.isDirty else { continue }
                if case .saving = buf.state { continue }

                // 读命令也会触发本刷新。内容没变时不要重复给 text/imageData 赋值，
                // 否则编辑器会做一次无意义的全文更新，光标/选区也可能被扰动。
                if !Self.downloadedDataMatchesCurrentContent(data, of: buf) {
                    guard Self.applyDownloadedData(data, to: buf) else { continue }
                }

                let latest = (try? await sftp.stat(buf.remotePath)) ?? remote
                guard generation == remoteCommandRefreshGeneration else { return }
                buf.byteSize = latest.size
                buf.mtimeWhenLoaded = latest.mtime
                buf.state = .loaded
                didReload = true
            } catch {
                // 当前可见文件不能静默保留旧快照；非活动标签则保留现状，避免一次
                // 瞬时网络错误把所有后台标签都切成失败页。
                if buf.id == visibleID, !buf.isDirty {
                    Self.applyPreviewLoadFailure(error, to: buf)
                }
            }
        }

        if didReload {
            // Agent 也可能同时改动 Markdown 引用的同主机图片。
            markdownImageCache.removeAll()
        }
    }

    private func load(_ buf: FileBuffer, failIfProviderMissing: Bool) async {
        markdownImageRequests[buf.id] = nil
        // 与 open() 同序：类型先于大小。
        if let reason = Self.unsupportedPreviewReason(forPath: buf.remotePath) {
            buf.state = .failed(reason)
            return
        }

        if let byteSize = buf.byteSize, byteSize > Self.maximumPreviewBytes {
            buf.state = .failed(String(localized: "文件超过 50 MB，用本机应用打开"))
            return
        }

        guard let sftp = provider(for: buf) else {
            if failIfProviderMissing {
                buf.state = .failed(String(localized: "SFTP 尚未连接"))
            }
            return
        }

        do {
            let data = try await sftp.download(
                remotePath: buf.remotePath,
                maximumBytes: Int(Self.maximumPreviewBytes))
            buf.byteSize = Int64(data.count)
            guard Self.applyDownloadedData(data, to: buf) else { return }
            // mtime 未外部提供时，stat 获取真实值，供后续 save() 冲突检测
            if buf.mtimeWhenLoaded == nil {
                buf.mtimeWhenLoaded = (try? await sftp.stat(buf.remotePath))?.mtime
            }
            buf.state = .loaded
            buf.autosaveIssue = nil
            // 更新 recents（游离文档可能在另一台主机上，不进本窗口的「最近打开」）
            guard detached[buf.id] == nil else { return }
            recentsStore.touch(RecentFileEntry(
                remotePath: buf.remotePath,
                kindTag: kindTag(for: buf.kind),
                lastOpenedAt: Date()))
            recents = recentsStore.load()
        } catch {
            Self.applyPreviewLoadFailure(error, to: buf)
        }
    }

    func download(_ buffer: FileBuffer, to localURL: URL) async throws {
        guard knownBuffer(buffer.id) != nil else {
            throw PreviewDownloadError.missingBuffer
        }
        guard let sftp = provider(for: buffer) else {
            throw PreviewDownloadError.providerUnavailable
        }
        try await sftp.download(
            remotePath: buffer.remotePath,
            toLocalURL: localURL,
            onProgress: nil)
    }

    func loadMarkdownImage(source: String, referencedBy buffer: FileBuffer) async throws -> Data {
        guard knownBuffer(buffer.id) != nil else {
            throw PreviewDownloadError.missingBuffer
        }

        let resource = try Self.markdownImageResource(source: source, baseRemotePath: buffer.remotePath)
        if let cached = markdownImageCache[resource.cacheKey] {
            return cached
        }

        let data: Data
        switch resource {
        case .remotePath(let path):
            guard let sftp = provider(for: buffer) else {
                throw PreviewDownloadError.providerUnavailable
            }
            var requested = markdownImageRequests[buffer.id] ?? []
            if !requested.contains(path.remoteKey) {
                guard requested.count < MarkdownImageCache.maxEntryCount else {
                    throw PreviewDownloadError.tooManyMarkdownImages
                }
                requested.insert(path.remoteKey)
                markdownImageRequests[buffer.id] = requested
            }
            // 先 stat：只读普通文件（FIFO、设备读了会卡住侧栏共用的会话，见 `TerminalLinkTarget`），太大的不下。
            let stat = try await sftp.stat(path)
            guard TerminalLinkTarget.isOpenableFile(stat) else { throw PreviewDownloadError.markdownImageNotAFile }
            guard stat.size <= MarkdownImageCache.perImageByteCap else {
                throw PreviewDownloadError.markdownImageTooLarge(bytes: Int(clamping: stat.size))
            }
            do {
                data = try await sftp.download(
                    remotePath: path,
                    maximumBytes: MarkdownImageCache.perImageByteCap)
            } catch let error as SFTPDownloadLimitExceeded {
                let clamped = min(error.observedBytes, Int64(Int.max))
                throw PreviewDownloadError.markdownImageTooLarge(bytes: Int(clamped))
            }
        }

        // 单图体积上限：超限直接拒绝，避免巨图把内存撑爆。
        guard data.count <= MarkdownImageCache.perImageByteCap else {
            throw PreviewDownloadError.markdownImageTooLarge(bytes: data.count)
        }

        // 写入有界缓存（按插入顺序淘汰最旧条目），防止大量远程图累积。
        markdownImageCache.insert(data, forKey: resource.cacheKey)
        return data
    }

    /// 关一个标签。文档由 `onTabRemoved` 的引用计数负责释放。
    /// 脏文件确认在上层（`WorkspaceWindowView.requestCloseTab`），这里是真关。
    @discardableResult
    func closeTab(_ tabID: UUID) -> Bool {
        guard let at = panes.locateTab(tabID) else { return false }
        panes.closeTab(groupID: at.groupID, index: at.index)
        return true
    }

    func save(_ id: UUID) async -> SaveOutcome {
        guard let buf = knownBuffer(id) else { return .noop }
        // image 不写回；其它种类（code/markdown/plainText）都允许保存
        switch buf.kind {
        case .image: return .noop
        case .code, .markdown, .plainText: break
        }
        guard case .loaded = buf.state else { return .noop }
        guard buf.isDirty else { return .noop }
        guard let sftp = provider(for: buf) else { return .failed(String(localized: "SFTP 尚未连接")) }
        // 这一次写的就是最新内容，排着的自动保存不用再跑。
        cancelAutosave(id)
        // 先标成保存中：stat 期间再来一次保存（自动保存到点、⌘S）直接 noop，不会写两遍。
        buf.state = .saving

        // mtime 冲突检测
        do {
            let stat = try await sftp.stat(buf.remotePath)
            if let local = buf.mtimeWhenLoaded, stat.mtime > local {
                buf.state = .loaded
                return .conflict(remoteMtime: stat.mtime)
            }
        } catch {
            // stat 失败不阻塞 —— 文件可能是新建（无 mtimeWhenLoaded）
        }

        // 写的是这一刻的内容；写的途中用户接着打字，那些字还没存，不能清掉「未保存」。
        let version = buf.textVersion
        let data = Data(buf.text.utf8)
        do {
            try await sftp.write(buf.remotePath, data: data)
            let newStat = try? await sftp.stat(buf.remotePath)
            buf.mtimeWhenLoaded = newStat?.mtime ?? Date()
            buf.state = .loaded
            buf.autosaveIssue = nil
            if buf.textVersion == version {
                buf.isDirty = false
            } else {
                scheduleAutosave(buf)
            }
            promoteTransientTabs(for: buf)   // 保存过的文件不该再被下一次单击顶掉
            return .saved
        } catch {
            // 写失败时内容还在、还能接着改：留在编辑器里，不换成失败页。
            buf.state = .loaded
            return .failed(error.localizedDescription)
        }
    }

    // MARK: 自动保存

    /// 用户改了内容：停 `autosaveDelay` 没再改就写回。远端被别处改过（冲突）之后不再自动存，等用户 ⌘S 决定。
    private func scheduleAutosave(_ buf: FileBuffer) {
        guard isAutosaveEnabled(), buf.autosaveIssue != .conflict else { return }
        autosaveTasks[buf.id]?.cancel()
        let delay = autosaveDelay
        autosaveTasks[buf.id] = Task { [weak self, weak buf] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let buf else { return }
            self.autosaveTasks[buf.id] = nil
            await self.autosave(buf)
        }
    }

    private func autosave(_ buf: FileBuffer) async {
        guard knownBuffer(buf.id) === buf, buf.isDirty else { return }
        // 上一次还没写完：等它写完再排（它写完时内容变了会自己再排一次）。
        if case .saving = buf.state { return }
        switch await save(buf.id) {
        case .conflict: buf.autosaveIssue = .conflict
        case .failed(let message): buf.autosaveIssue = .failed(message)
        case .saved, .noop: break
        }
    }

    /// 改了没存的文档：预览区的和终端区的（游离）都算。图片不会脏。
    var unsavedBuffers: [FileBuffer] {
        (buffers + detached.values.map(\.buffer)).filter(\.isDirty)
    }

    /// 关窗 / 退出前：不等自动保存的那一秒，立刻全存。正在写的等它写完再看（写的途中又改了就再存一次）。
    /// 返回存不上的（远端被别处改过、写失败）。
    func saveAllUnsaved() async -> [FileBuffer] {
        for buf in unsavedBuffers {
            for _ in 0..<500 {   // 最多等 10 秒
                guard case .saving = buf.state else { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            switch await save(buf.id) {
            case .conflict: buf.autosaveIssue = .conflict
            case .failed(let message): buf.autosaveIssue = .failed(message)
            case .saved, .noop: break
            }
            // 写的途中又改了：save 已经排了自动保存，这里不等那一秒，再存一次。
            if buf.isDirty, case .loaded = buf.state, buf.autosaveIssue == nil {
                _ = await save(buf.id)
            }
        }
        return unsavedBuffers
    }

    private func cancelAutosave(_ id: UUID) {
        autosaveTasks.removeValue(forKey: id)?.cancel()
    }

    /// 冲突 dialog 用户选「用远程的」时调。重读 + 清 dirty。
    func reloadFromRemote(_ id: UUID) async {
        guard let buf = knownBuffer(id) else { return }
        guard let sftp = provider(for: buf) else { return }
        do {
            let data = try await sftp.download(
                remotePath: buf.remotePath,
                maximumBytes: Int(Self.maximumPreviewBytes))
            buf.byteSize = Int64(data.count)
            guard Self.applyDownloadedData(data, to: buf) else { return }
            let stat = try? await sftp.stat(buf.remotePath)
            buf.mtimeWhenLoaded = stat?.mtime
            buf.isDirty = false
            buf.state = .loaded
            buf.autosaveIssue = nil
        } catch {
            buf.state = .failed("\(error)")
        }
    }

    /// EmptyBody 行点击 → 重开。
    func reopen(_ entry: RecentFileEntry) async {
        // 最近记录没有可信 size；load 内部仍会用有界下载强制执行 50 MB 上限。
        await open(path: entry.remotePath, fileSize: nil, mtime: nil)
    }

    func clearRecents() {
        recentsStore.save([])
        recents = []
    }

    func dispose() {
        remoteCommandRefreshGeneration &+= 1
        for buf in buffers { buf.onBecameDirty = nil }
        for task in autosaveTasks.values { task.cancel() }
        autosaveTasks.removeAll()
        buffers.removeAll()
        editorFocusRequest = nil
        // reset 不走 onTabRemoved —— 释放整个工作区不是逐个关标签。
        panes.reset()
        markdownImageCache.removeAll()
    }

    func clearMarkdownImageCache() {
        markdownImageCache.removeAll()
    }

    private func kindTag(for kind: FileKind) -> String {
        switch kind {
        case .code(let lang): return "code:\(lang)"
        case .markdown:       return "markdown"
        case .image:          return "image"
        case .plainText:      return "text"
        }
    }

    private static func applyDownloadedData(_ data: Data, to buf: FileBuffer) -> Bool {
        switch buf.kind {
        case .image:
            // 先看声明的像素尺寸（`RemoteImageGuard`）：几 MB 的图可以声明几十亿像素，整张解码会把 App 撑死。
            guard RemoteImageGuard.admits(data), let img = NSImage(data: data) else {
                buf.imageData = nil
                buf.imageSize = .zero
                buf.state = .failed(RemoteImageGuard.pixelSize(of: data) != nil
                    ? String(localized: "图片像素太多，不支持预览。可以用本机应用打开。")
                    : String(localized: "图片无法解码，不支持预览。可以用本机应用打开，保存后自动上传回主机。"))
                return false
            }
            buf.imageData = data
            buf.imageSize = img.size
        case .code, .markdown, .plainText:
            guard let text = previewableText(from: data) else {
                buf.text = ""
                buf.state = .failed(String(localized: "检测到二进制内容，不支持预览。可以用本机应用打开，保存后自动上传回主机。"))
                return false
            }
            buf.text = text
        }
        return true
    }

    private static func applyPreviewLoadFailure(_ error: Error, to buf: FileBuffer) {
        if let limitError = error as? SFTPDownloadLimitExceeded {
            buf.byteSize = limitError.observedBytes
            buf.state = .failed(String(localized: "文件超过 50 MB，用本机应用打开"))
        } else {
            buf.state = .failed("\(error)")
        }
    }

    private static func downloadedDataMatchesCurrentContent(_ data: Data,
                                                            of buf: FileBuffer) -> Bool {
        switch buf.kind {
        case .image:
            return buf.imageData == data
        case .code, .markdown, .plainText:
            guard let text = previewableText(from: data) else { return false }
            return buf.text == text
        }
    }

    private static func previewableText(from data: Data) -> String? {
        guard !containsBinaryControlByte(data),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func containsBinaryControlByte(_ data: Data) -> Bool {
        data.contains { byte in
            byte == 0 || byte < 0x09 || (byte > 0x0D && byte < 0x20)
        }
    }

    /// 与打开门（`WorkspaceRemoteFileOpenGate`）共用同一份类型名单 —— 两处判据分家
    /// 的话，命令面板/最近文件这些不走门的入口就会漏进来。
    private static func unsupportedPreviewReason(forPath path: String) -> String? {
        PreviewFileType.unsupportedReason(forPath: path)
    }

    private enum MarkdownImageResource {
        case remotePath(String)

        var cacheKey: RemoteNameKey {
            switch self {
            case .remotePath(let path): return RemoteNameKey("sftp:\(path)")
            }
        }
    }

    private static func markdownImageResource(source: String,
                                              baseRemotePath: String) throws -> MarkdownImageResource {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PreviewDownloadError.invalidMarkdownImageSource
        }

        switch RemoteMarkdownImagePath.resolve(trimmed, documentPath: baseRemotePath) {
        case .external:
            // 远程 Markdown 属于不可信输入。自动访问其中的 http(s) 地址会泄漏
            // 本机网络可达性/IP，并可被用来探测 localhost、路由器或云元数据服务。
            // 图片必须留在已经通过 SSH 主机密钥验证的 SFTP 信任边界内。
            throw PreviewDownloadError.unsupportedMarkdownImageSource(trimmed)
        case .invalid:
            throw PreviewDownloadError.invalidMarkdownImageSource
        case .path(let path):
            return .remotePath(path)
        }
    }

}

// MARK: 带提示的保存（⌘S、关标签）

extension FilePreviewModel {
    /// ⌘S：远端在打开之后被改过就问「覆盖 / 放弃本地改动 / 取消」，写失败说原因。预览区与终端区的文件标签共用。
    func saveInteractively(_ id: UUID) async {
        switch await save(id) {
        case .conflict(let remoteMtime):
            let alert = NSAlert()
            alert.messageText = String(localized: "远程文件已变化")
            alert.informativeText = String(localized: "这个文件在你打开后被别处改过。覆盖会丢掉那些改动。")
            alert.addButton(withTitle: String(localized: "覆盖远程文件"))
            alert.addButton(withTitle: String(localized: "放弃本地改动"))
            alert.addButton(withTitle: String(localized: "取消"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // 强制覆盖：把基准推到远程值绕过冲突检查
                knownBufferForSave(id)?.mtimeWhenLoaded = remoteMtime
                _ = await save(id)
            case .alertSecondButtonReturn:
                await reloadFromRemote(id)
            default: break
            }
        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = String(localized: "保存失败")
            alert.informativeText = message
            alert.runModal()
        case .saved, .noop: break
        }
    }

    /// 关掉最后一个引用这个文档的标签。没改过直接关；自动保存开着就先存（冲突、失败照 ⌘S 那样问），存好了才关；
    /// 关着就问「保存 / 不保存 / 取消」。
    func closeAfterSaving(_ buf: FileBuffer, close: @escaping @MainActor () -> Void) {
        guard buf.isDirty else { return close() }
        if isAutosaveEnabled() {
            Task { @MainActor in
                await saveInteractively(buf.id)
                if !buf.isDirty { close() }
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "是否保存对「\(buf.displayName)」的更改？")
        alert.informativeText = String(localized: "如果不保存，你的更改将丢失。")
        alert.addButton(withTitle: String(localized: "保存"))
        alert.addButton(withTitle: String(localized: "不保存"))
        alert.addButton(withTitle: String(localized: "取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await saveInteractively(buf.id)
                if !buf.isDirty { close() }   // 仅保存成功才关
            }
        case .alertSecondButtonReturn:
            close()
        default:
            break
        }
    }
}
