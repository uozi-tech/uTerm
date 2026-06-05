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

@MainActor
@Observable
final class FilePreviewModel {
    private(set) var buffers: [FileBuffer] = []
    var activeBufferID: UUID?
    private(set) var panelRoot: LayoutNode?
    private(set) var panels: [UUID: FilePreviewPanel] = [:]
    var focusedPanelID: UUID?
    private(set) var recents: [RecentFileEntry] = []

    enum SaveOutcome {
        case saved
        case conflict(remoteMtime: Date)
        case failed(String)
        case noop
    }

    enum PreviewDownloadError: LocalizedError {
        case providerUnavailable
        case missingBuffer

        var errorDescription: String? {
            switch self {
            case .providerUnavailable:
                return "SFTP 通道未就绪"
            case .missingBuffer:
                return "文件缓冲区不存在"
            }
        }
    }

    private let recentsStore: RecentFilesStore
    /// 工厂：每次取一个最新的 SFTP provider（由 WorkspaceModel 注入；
    /// 共享 FileBrowserModel 的 SFTP 会话）。
    private let sftpProvider: () -> (any SFTPProviding)?

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
    }

    func selectPanel(_ id: UUID) {
        guard let panel = panels[id] else { return }
        focusedPanelID = id
        activeBufferID = panel.bufferID
    }

    /// SFTPSidebar 文件 tap → 通知 → 调用。
    func open(path: String, fileSize: Int64, mtime: Date?) async {
        // 已打开则只切 tab
        if let existing = buffers.first(where: { $0.remotePath == path }) {
            activeBufferID = existing.id
            assignActiveBufferToFocusedPanel()
            return
        }

        let kind = LanguageDetector.kind(forPath: path)
        let buf = FileBuffer(remotePath: path, kind: kind)
        buf.byteSize = fileSize
        buf.mtimeWhenLoaded = mtime
        buffers.append(buf)
        activeBufferID = buf.id
        assignActiveBufferToFocusedPanel()

        // 大小检查
        if fileSize > 50 * 1024 * 1024 {
            buf.state = .failed("文件超过 50 MB，请用外部编辑器")
            return
        }

        if let reason = Self.unsupportedPreviewReason(forPath: path) {
            buf.state = .failed(reason)
            return
        }

        await load(buf, failIfProviderMissing: true)
    }

    func restoreOpenFiles(_ snapshots: [OpenFileSnapshot]?, activeIndex: Int?) {
        buffers.removeAll()
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

    private func load(_ buf: FileBuffer, failIfProviderMissing: Bool) async {
        if buf.byteSize > 50 * 1024 * 1024 {
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
            let data = try await sftp.download(remotePath: buf.remotePath)
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
            buf.state = .failed("\(error)")
        }
    }

    func download(_ buffer: FileBuffer) async throws -> Data {
        guard buffers.contains(where: { $0.id == buffer.id }) else {
            throw PreviewDownloadError.missingBuffer
        }
        guard let sftp = sftpProvider() else {
            throw PreviewDownloadError.providerUnavailable
        }
        return try await sftp.download(remotePath: buffer.remotePath)
    }

    @discardableResult
    func close(_ id: UUID, savingIfDirty: Bool) -> Bool {
        guard let idx = buffers.firstIndex(where: { $0.id == id }) else { return false }
        buffers.remove(at: idx)
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
            return .saved
        } catch {
            buf.state = .failed("\(error)")
            return .failed("\(error)")
        }
    }

    /// 冲突 dialog 用户选「用远程的」时调。重读 + 清 dirty。
    func reloadFromRemote(_ id: UUID) async {
        guard let buf = buffers.first(where: { $0.id == id }) else { return }
        guard let sftp = sftpProvider() else { return }
        do {
            let data = try await sftp.download(remotePath: buf.remotePath)
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
        // 大小未知（不在 entry 里），open 走默认 0 → 不会触发 50MB 阻断
        await open(path: entry.remotePath, fileSize: 0, mtime: nil)
    }

    func clearRecents() {
        recentsStore.save([])
        recents = []
    }

    func dispose() {
        buffers.removeAll()
        activeBufferID = nil
        panelRoot = nil
        panels.removeAll()
        focusedPanelID = nil
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
}
