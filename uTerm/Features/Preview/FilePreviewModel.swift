import UPaneTree
import SwiftUI
import AppKit

nonisolated struct FilePreviewPanel: Identifiable, Equatable, Sendable {
    let id: UUID
    var bufferID: UUID

    init(id: UUID = UUID(), bufferID: UUID) {
        self.id = id
        self.bufferID = bufferID
    }
}

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
    private var order: [String] = []
    private var storage: [String: Data] = [:]
    private(set) var totalBytes = 0

    init(perImageByteCap: Int = MarkdownImageCache.perImageByteCap,
         totalByteCap: Int = MarkdownImageCache.totalByteCap,
         maxEntryCount: Int = MarkdownImageCache.maxEntryCount) {
        self.perImageByteCap = perImageByteCap
        self.totalByteCap = totalByteCap
        self.maxEntryCount = maxEntryCount
    }

    var count: Int { storage.count }

    subscript(key: String) -> Data? { storage[key] }

    /// 插入一条。超出单图上限的不缓存；插入后按总字节/条目数上限从最旧开始淘汰。
    /// 返回是否成功缓存（超单图上限时为 false）。
    @discardableResult
    mutating func insert(_ data: Data, forKey key: String) -> Bool {
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

    private(set) var buffers: [FileBuffer] = []
    var activeBufferID: UUID?
    /// 预览（临时）tab 的 buffer id（VS Code 风）：侧栏单击以预览方式打开，下一次
    /// 预览打开会**顶替**它；双击 / 编辑 / 保存 / 拖拽分屏则「转正」（置 nil）。
    /// 全局至多一个预览 tab。
    private(set) var previewTabBufferID: UUID?
    private(set) var panelRoot: LayoutNode?
    private(set) var panels: [UUID: FilePreviewPanel] = [:]
    var focusedPanelID: UUID?
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

        var errorDescription: String? {
            switch self {
            case .providerUnavailable:
                return "SFTP 通道未就绪"
            case .missingBuffer:
                return "文件缓冲区不存在"
            case .invalidMarkdownImageSource:
                return "图片地址为空或无效"
            case .unsupportedMarkdownImageSource(let source):
                return "为保护本机网络，Markdown 只预览同一 SFTP 主机上的图片：\(source)"
            case .markdownImageTooLarge(let bytes):
                let cap = Double(MarkdownImageCache.perImageByteCap) / (1024 * 1024)
                let actual = Double(bytes) / (1024 * 1024)
                return String(format: "图片超过 %.0f MB（实际约 %.1f MB），已跳过预览", cap, actual)
            }
        }
    }

    private let recentsStore: RecentFilesStore
    /// 工厂：每次取一个最新的 SFTP provider（由 WorkspaceModel 注入；
    /// 共享 FileBrowserModel 的 SFTP 会话）。
    private let sftpProvider: () -> (any SFTPProviding)?
    private var markdownImageCache = MarkdownImageCache()
    private var remoteCommandRefreshGeneration = 0

    init(recentsStore: RecentFilesStore,
         sftpProvider: @escaping () -> (any SFTPProviding)?) {
        self.recentsStore = recentsStore
        self.sftpProvider = sftpProvider
        self.recents = recentsStore.load()
    }

    var activeBuffer: FileBuffer? { buffers.first { $0.id == activeBufferID } }

    var panelBufferIDsInDisplayOrder: [UUID] {
        guard let panelRoot else { return [] }
        return panelRoot.leafIDs.compactMap { panels[$0]?.bufferID }
    }

    var hasMultiplePanels: Bool {
        (panelRoot?.leafCount ?? 0) > 1
    }

    func buffer(forPanel panelID: UUID) -> FileBuffer? {
        guard let bufferID = panels[panelID]?.bufferID else { return nil }
        return buffers.first { $0.id == bufferID }
    }

    func selectTab(_ id: UUID) {
        guard buffers.contains(where: { $0.id == id }) else { return }
        activeBufferID = id
        assignActiveBufferToFocusedPanel()
        requestEditorFocus(id)
    }

    /// 用户主动打开 / 切换文件 → 请求把键盘焦点交给对应编辑器。
    private func requestEditorFocus(_ bufferID: UUID) {
        let next = (editorFocusRequest?.generation ?? 0) + 1
        editorFocusRequest = EditorFocusRequest(generation: next, bufferID: bufferID)
    }

    func selectPanel(_ id: UUID) {
        guard let panel = panels[id] else { return }
        focusedPanelID = id
        activeBufferID = panel.bufferID
    }

    /// SFTPSidebar 文件 tap → 通知 → 调用。`asPreview` = 以预览（临时）tab 打开：
    /// 顶替现有预览 tab 而不是新增；永久打开（双击）同一路径会把预览 tab 转正。
    func open(path: String, fileSize: Int64?, mtime: Date?, asPreview: Bool = false) async {
        // 已打开则只切 tab；永久打开命中预览 tab 时转正。
        if let existing = buffers.first(where: { $0.remotePath == path }) {
            activeBufferID = existing.id
            assignActiveBufferToFocusedPanel()
            if !asPreview { keepTab(existing.id) }
            requestEditorFocus(existing.id)
            return
        }

        let kind = LanguageDetector.kind(forPath: path)
        let buf = FileBuffer(remotePath: path, kind: kind)
        buf.byteSize = fileSize
        buf.mtimeWhenLoaded = mtime
        if asPreview {
            insertReplacingPreviewTab(buf)
        } else {
            buffers.append(buf)
        }
        activeBufferID = buf.id
        assignActiveBufferToFocusedPanel()
        requestEditorFocus(buf.id)

        // 大小检查
        if let fileSize, fileSize > Self.maximumPreviewBytes {
            buf.state = .failed("文件超过 50 MB，请用外部编辑器")
            return
        }

        if let reason = Self.unsupportedPreviewReason(forPath: path) {
            buf.state = .failed(reason)
            return
        }

        await load(buf, failIfProviderMissing: true)
    }

    /// 该 buffer 是否处于「预览（临时）」状态。编辑中（脏）即视作已转正 ——
    /// 与 VS Code 一致：改动过的内容不能被下一次单击顶掉。
    func isPreviewTab(_ id: UUID) -> Bool {
        guard id == previewTabBufferID,
              let buf = buffers.first(where: { $0.id == id }) else { return false }
        return !buf.isDirty
    }

    /// 把预览 tab 转正（双击 tab / 永久打开同一文件 / 保存 / 拖拽分屏时调用）。
    func keepTab(_ id: UUID) {
        if previewTabBufferID == id { previewTabBufferID = nil }
    }

    /// 新预览 buffer 顶替旧预览 tab 的位置（tab 不位移）；脏的旧预览不能丢 ——
    /// 原地转正保留，新预览追加在末尾。
    private func insertReplacingPreviewTab(_ buf: FileBuffer) {
        defer { previewTabBufferID = buf.id }
        guard let oldID = previewTabBufferID,
              let oldIdx = buffers.firstIndex(where: { $0.id == oldID }),
              !buffers[oldIdx].isDirty else {
            buffers.append(buf)
            return
        }
        buffers[oldIdx] = buf
        // 分屏面板可能引用被顶替的 buffer，一并改指新 buffer，避免悬空 id。
        for panelID in Array(panels.keys) where panels[panelID]?.bufferID == oldID {
            panels[panelID]?.bufferID = buf.id
        }
        if activeBufferID == oldID { activeBufferID = buf.id }
    }

    func restoreOpenFiles(_ snapshots: [OpenFileSnapshot]?, activeIndex: Int?) {
        buffers.removeAll()
        previewTabBufferID = nil   // 恢复的标签一律永久
        let snapshots = snapshots ?? []
        for snapshot in snapshots {
            let buf = FileBuffer(
                remotePath: snapshot.remotePath,
                kind: LanguageDetector.kind(forPath: snapshot.remotePath))
            buf.byteSize = snapshot.byteSize
            buf.mtimeWhenLoaded = snapshot.mtimeWhenLoaded
            buffers.append(buf)
        }
        if let activeIndex, buffers.indices.contains(activeIndex) {
            activeBufferID = buffers[activeIndex].id
        } else {
            activeBufferID = buffers.first?.id
        }
        rebuildSinglePanelForActiveBuffer()
    }

    func openFileSnapshots() -> ([OpenFileSnapshot], Int?) {
        var activeIndex: Int?
        let snapshots = buffers.enumerated().map { index, buf in
            if buf.id == activeBufferID {
                activeIndex = index
            }
            return OpenFileSnapshot(
                remotePath: buf.remotePath,
                byteSize: buf.byteSize,
                mtimeWhenLoaded: buf.mtimeWhenLoaded)
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
                    buf.state = .failed("文件超过 50 MB，请用外部编辑器")
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
        if let byteSize = buf.byteSize, byteSize > Self.maximumPreviewBytes {
            buf.state = .failed("文件超过 50 MB，请用外部编辑器")
            return
        }

        if let reason = Self.unsupportedPreviewReason(forPath: buf.remotePath) {
            buf.state = .failed(reason)
            return
        }

        guard let sftp = sftpProvider() else {
            if failIfProviderMissing {
                buf.state = .failed("SFTP 通道未就绪")
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
            // 更新 recents
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
        guard buffers.contains(where: { $0.id == buffer.id }) else {
            throw PreviewDownloadError.missingBuffer
        }
        guard let sftp = sftpProvider() else {
            throw PreviewDownloadError.providerUnavailable
        }
        try await sftp.download(
            remotePath: buffer.remotePath,
            toLocalURL: localURL,
            onProgress: nil)
    }

    func loadMarkdownImage(source: String, referencedBy buffer: FileBuffer) async throws -> Data {
        guard buffers.contains(where: { $0.id == buffer.id }) else {
            throw PreviewDownloadError.missingBuffer
        }

        let resource = try Self.markdownImageResource(source: source, baseRemotePath: buffer.remotePath)
        if let cached = markdownImageCache[resource.cacheKey] {
            return cached
        }

        let data: Data
        switch resource {
        case .remotePath(let path):
            guard let sftp = sftpProvider() else {
                throw PreviewDownloadError.providerUnavailable
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

    @discardableResult
    func close(_ id: UUID, savingIfDirty: Bool) -> Bool {
        guard let idx = buffers.firstIndex(where: { $0.id == id }) else { return false }
        buffers.remove(at: idx)
        if previewTabBufferID == id { previewTabBufferID = nil }
        if activeBufferID == id {
            activeBufferID = buffers.first?.id
        }
        reconcilePanelsAfterClosingBuffer(id)
        return true
    }

    @discardableResult
    func dropBufferOntoFocusedPanel(_ bufferID: UUID, zone: PaneDropZone) -> Bool {
        guard let targetPanelID = focusedPanelID ?? panelRoot?.firstLeafID else {
            return false
        }
        return dropBuffer(bufferID, onto: targetPanelID, zone: zone)
    }

    @discardableResult
    func dropBuffer(_ bufferID: UUID, onto targetPanelID: UUID,
                    zone: PaneDropZone) -> Bool {
        guard zone != .center,
              buffers.contains(where: { $0.id == bufferID }),
              let panelRoot,
              panels[targetPanelID] != nil
        else {
            return false
        }

        let direction: SplitDirection
        let newLeafFirst: Bool
        switch zone {
        case .leading:  direction = .horizontal; newLeafFirst = true
        case .trailing: direction = .horizontal; newLeafFirst = false
        case .top:      direction = .vertical;   newLeafFirst = true
        case .bottom:   direction = .vertical;   newLeafFirst = false
        case .center:   return false
        }

        let panel = FilePreviewPanel(bufferID: bufferID)
        panels[panel.id] = panel
        self.panelRoot = panelRoot.splitting(
            paneID: targetPanelID,
            direction: direction,
            newPaneID: panel.id,
            splitID: UUID(),
            newLeafFirst: newLeafFirst)
        focusedPanelID = panel.id
        activeBufferID = bufferID
        keepTab(bufferID)   // 拖去分屏 = 用户要留着它，预览转正
        return true
    }

    @discardableResult
    func closePanel(_ panelID: UUID) -> Bool {
        guard let panelRoot,
              panelRoot.leafCount > 1,
              let newRoot = panelRoot.removingLeaf(paneID: panelID)
        else {
            return false
        }

        panels[panelID] = nil
        self.panelRoot = newRoot
        if focusedPanelID == panelID {
            focusedPanelID = newRoot.firstLeafID
        }
        if let focusedPanelID,
           let bufferID = panels[focusedPanelID]?.bufferID {
            activeBufferID = bufferID
        }
        return true
    }

    func setPanelFraction(_ fraction: Double, splitID: UUID) {
        panelRoot = panelRoot?.settingFraction(fraction, splitID: splitID)
    }

    func save(_ id: UUID) async -> SaveOutcome {
        guard let buf = buffers.first(where: { $0.id == id }) else { return .noop }
        // image 不写回；其它种类（code/markdown/plainText）都允许保存
        switch buf.kind {
        case .image: return .noop
        case .code, .markdown, .plainText: break
        }
        guard case .loaded = buf.state else { return .noop }
        guard buf.isDirty else { return .noop }
        guard let sftp = sftpProvider() else { return .failed("SFTP 通道未就绪") }

        // mtime 冲突检测
        do {
            let stat = try await sftp.stat(buf.remotePath)
            if let local = buf.mtimeWhenLoaded, stat.mtime > local {
                return .conflict(remoteMtime: stat.mtime)
            }
        } catch {
            // stat 失败不阻塞 —— 文件可能是新建（无 mtimeWhenLoaded）
        }

        buf.state = .saving
        do {
            let data = Data(buf.text.utf8)
            try await sftp.write(buf.remotePath, data: data)
            let newStat = try? await sftp.stat(buf.remotePath)
            buf.mtimeWhenLoaded = newStat?.mtime ?? Date()
            buf.isDirty = false
            buf.state = .loaded
            keepTab(id)   // 保存过的文件不该再被下一次单击顶掉
            return .saved
        } catch {
            Self.applyPreviewLoadFailure(error, to: buf)
            return .failed("\(error)")
        }
    }

    /// 冲突 dialog 用户选「用远程的」时调。重读 + 清 dirty。
    func reloadFromRemote(_ id: UUID) async {
        guard let buf = buffers.first(where: { $0.id == id }) else { return }
        guard let sftp = sftpProvider() else { return }
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
        buffers.removeAll()
        activeBufferID = nil
        previewTabBufferID = nil
        editorFocusRequest = nil
        panelRoot = nil
        panels.removeAll()
        focusedPanelID = nil
        markdownImageCache.removeAll()
    }

    func clearMarkdownImageCache() {
        markdownImageCache.removeAll()
    }

    private func assignActiveBufferToFocusedPanel() {
        guard let activeBufferID else {
            panelRoot = nil
            panels.removeAll()
            focusedPanelID = nil
            return
        }

        if panelRoot == nil {
            let panel = FilePreviewPanel(bufferID: activeBufferID)
            panelRoot = .leaf(paneID: panel.id)
            panels = [panel.id: panel]
            focusedPanelID = panel.id
            return
        }

        let targetID = focusedPanelID ?? panelRoot?.firstLeafID
        guard let targetID, var panel = panels[targetID] else {
            rebuildSinglePanelForActiveBuffer()
            return
        }
        panel.bufferID = activeBufferID
        panels[targetID] = panel
        focusedPanelID = targetID
    }

    private func rebuildSinglePanelForActiveBuffer() {
        guard let activeBufferID else {
            panelRoot = nil
            panels.removeAll()
            focusedPanelID = nil
            return
        }

        let panel = FilePreviewPanel(bufferID: activeBufferID)
        panelRoot = .leaf(paneID: panel.id)
        panels = [panel.id: panel]
        focusedPanelID = panel.id
    }

    private func reconcilePanelsAfterClosingBuffer(_ closedID: UUID) {
        guard let fallbackID = activeBufferID else {
            panelRoot = nil
            panels.removeAll()
            focusedPanelID = nil
            return
        }

        for panelID in Array(panels.keys) {
            guard panels[panelID]?.bufferID == closedID else { continue }
            var panel = panels[panelID]
            panel?.bufferID = fallbackID
            panels[panelID] = panel
        }
        if let focusedPanelID,
           let bufferID = panels[focusedPanelID]?.bufferID {
            activeBufferID = bufferID
        }
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
            guard let img = NSImage(data: data) else {
                buf.imageData = nil
                buf.imageSize = .zero
                buf.state = .failed("图片无法解码，不支持预览。请下载到本地后使用外部应用打开。")
                return false
            }
            buf.imageData = data
            buf.imageSize = img.size
        case .code, .markdown, .plainText:
            guard let text = previewableText(from: data) else {
                buf.text = ""
                buf.state = .failed("检测到二进制内容，不支持预览。请下载到本地后使用外部应用打开。")
                return false
            }
            buf.text = text
        }
        return true
    }

    private static func applyPreviewLoadFailure(_ error: Error, to buf: FileBuffer) {
        if let limitError = error as? SFTPDownloadLimitExceeded {
            buf.byteSize = limitError.observedBytes
            buf.state = .failed("文件超过 50 MB，请用外部编辑器")
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

    private static func unsupportedPreviewReason(forPath path: String) -> String? {
        let ext = ((path as NSString).lastPathComponent as NSString)
            .pathExtension
            .lowercased()
        guard unsupportedPreviewExtensions.contains(ext) else { return nil }
        return "此文件类型不支持预览。请下载到本地后使用外部应用打开。"
    }

    private static let unsupportedPreviewExtensions: Set<String> = [
        "db", "db3", "sqlite", "sqlite3", "sqlite-shm", "sqlite-wal",
        "db-shm", "db-wal", "db-journal", "mdb", "accdb",
        "bin", "exe", "dll", "dylib", "so", "a", "o",
        "class", "jar", "war", "pyc", "pyo", "wasm",
        "pdf", "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar"
    ]

    private enum MarkdownImageResource {
        case remotePath(String)

        var cacheKey: String {
            switch self {
            case .remotePath(let path): return "sftp:\(path)"
            }
        }
    }

    private static func markdownImageResource(source: String,
                                              baseRemotePath: String) throws -> MarkdownImageResource {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PreviewDownloadError.invalidMarkdownImageSource
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           !scheme.isEmpty {
            // 远程 Markdown 属于不可信输入。自动访问其中的 http(s) 地址会泄漏
            // 本机网络可达性/IP，并可被用来探测 localhost、路由器或云元数据服务。
            // 图片必须留在已经通过 SSH 主机密钥验证的 SFTP 信任边界内。
            throw PreviewDownloadError.unsupportedMarkdownImageSource(trimmed)
        }

        let path = markdownImageRemotePath(source: trimmed, baseRemotePath: baseRemotePath)
        guard !path.isEmpty else {
            throw PreviewDownloadError.invalidMarkdownImageSource
        }
        return .remotePath(path)
    }

    private static func markdownImageRemotePath(source: String, baseRemotePath: String) -> String {
        let localSource = sanitizedLocalMarkdownResource(source)
        if localSource.hasPrefix("/") {
            return normalizedRemotePath(localSource)
        }

        let baseDir = remoteDirectory(of: baseRemotePath)
        return normalizedRemotePath(joinRemotePath(baseDir, localSource))
    }

    private static func sanitizedLocalMarkdownResource(_ source: String) -> String {
        let withoutFragment = source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? source
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? withoutFragment
        return withoutQuery.removingPercentEncoding ?? withoutQuery
    }

    private static func remoteDirectory(of path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }

    private static func joinRemotePath(_ baseDir: String, _ child: String) -> String {
        if baseDir.isEmpty { return child }
        if baseDir == "/" { return "/\(child)" }
        return "\(baseDir)/\(child)"
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var parts: [String] = []

        for rawPart in path.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(rawPart)
            switch part {
            case ".":
                continue
            case "..":
                if !parts.isEmpty {
                    parts.removeLast()
                } else if !isAbsolute {
                    parts.append(part)
                }
            default:
                parts.append(part)
            }
        }

        let joined = parts.joined(separator: "/")
        if isAbsolute {
            return joined.isEmpty ? "/" : "/\(joined)"
        }
        return joined
    }
}
