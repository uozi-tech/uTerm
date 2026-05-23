import SwiftUI
import AppKit

@MainActor
@Observable
final class FilePreviewModel {
    private(set) var buffers: [FileBuffer] = []
    var activeBufferID: UUID?
    private(set) var recents: [RecentFileEntry] = []

    enum SaveOutcome {
        case saved
        case conflict(remoteMtime: Date)
        case failed(String)
        case noop
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

    func selectTab(_ id: UUID) {
        guard buffers.contains(where: { $0.id == id }) else { return }
        activeBufferID = id
    }

    /// SFTPSidebar 文件 tap → 通知 → 调用。
    func open(path: String, fileSize: Int64, mtime: Date?) async {
        // 已打开则只切 tab
        if let existing = buffers.first(where: { $0.remotePath == path }) {
            activeBufferID = existing.id
            return
        }

        let kind = LanguageDetector.kind(forPath: path)
        let buf = FileBuffer(remotePath: path, kind: kind)
        buf.byteSize = fileSize
        buf.mtimeWhenLoaded = mtime
        buffers.append(buf)
        activeBufferID = buf.id

        // 大小检查
        if fileSize > 50 * 1024 * 1024 {
            buf.state = .failed("文件超过 50 MB，请用外部编辑器")
            return
        }

        guard let sftp = sftpProvider() else {
            buf.state = .failed("SFTP 通道未就绪")
            return
        }

        do {
            let data = try await sftp.download(remotePath: path)
            switch kind {
            case .image:
                buf.imageData = data
                if let img = NSImage(data: data) { buf.imageSize = img.size }
            default:
                buf.text = String(decoding: data, as: UTF8.self)
            }
            // mtime 未外部提供时，stat 获取真实值，供后续 save() 冲突检测
            if buf.mtimeWhenLoaded == nil {
                buf.mtimeWhenLoaded = (try? await sftp.stat(path))?.mtime
            }
            buf.state = .loaded
            // 更新 recents
            recentsStore.touch(RecentFileEntry(
                remotePath: path,
                kindTag: kindTag(for: kind),
                lastOpenedAt: Date()))
            recents = recentsStore.load()
        } catch {
            buf.state = .failed("\(error)")
        }
    }

    @discardableResult
    func close(_ id: UUID, savingIfDirty: Bool) -> Bool {
        guard let idx = buffers.firstIndex(where: { $0.id == id }) else { return false }
        buffers.remove(at: idx)
        if activeBufferID == id {
            activeBufferID = buffers.first?.id
        }
        return true
    }

    func save(_ id: UUID) async -> SaveOutcome {
        guard let buf = buffers.first(where: { $0.id == id }) else { return .noop }
        // image 不写回；其它种类（code/markdown/plainText）都允许保存
        switch buf.kind {
        case .image: return .noop
        case .code, .markdown, .plainText: break
        }
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
            buf.text = String(decoding: data, as: UTF8.self)
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
    }

    private func kindTag(for kind: FileKind) -> String {
        switch kind {
        case .code(let lang): return "code:\(lang)"
        case .markdown:       return "markdown"
        case .image:          return "image"
        case .plainText:      return "text"
        }
    }
}
