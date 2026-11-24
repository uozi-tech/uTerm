import AppKit
import Foundation
import UniformTypeIdentifiers

/// 外部打开用到的主机信息（从 `FileBrowserModel` 取，避免在这里持有 `@Model`）。
nonisolated struct ExternalOpenHost: Equatable, Sendable {
    let id: UUID
    let name: String
    /// uTable 的隧道只有单跳，带跳板机的主机交给它也连不上。
    let usesJumpHost: Bool
}

/// 「打开」要用到的系统交互。生产用 `.live`；测试注入假的（不弹框、不真起应用），
/// 这样「下载 → 外部应用存盘 → 自动上传 / 冲突」整条链路能在单测里真跑一遍文件系统。
struct ExternalOpenSystem {
    enum ConflictChoice { case keepMine, useRemote, cancel }

    /// 用应用打开本地文件：`nil` = 系统默认应用。返回是否成功。
    var launch: @MainActor (_ file: URL, _ application: URL?) async -> Bool
    /// 这类文件有没有系统默认应用。
    var hasDefaultApplication: @MainActor (_ path: String) -> Bool
    /// 让用户挑应用；nil = 取消。
    var chooseApplication: @MainActor (_ path: String) -> URL?
    var uTableAvailable: @MainActor () -> Bool
    var openInUTable: @MainActor (_ hostID: UUID, _ remotePath: String) async -> Bool
    var confirmOpenWhileInUse: @MainActor (_ fileName: String, _ companions: [String]) -> Bool
    var askConflict: @MainActor (_ fileName: String) -> ConflictChoice
    var confirmStopSync: @MainActor (_ fileName: String) -> Bool
    /// 暂存目录的根（生产 = 系统临时目录）。
    var stagingRoot: URL

    static let live = ExternalOpenSystem(
        launch: { file, application in
            guard let application else { return NSWorkspace.shared.open(file) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open(
                    [file], withApplicationAt: application, configuration: configuration)
                return true
            } catch {
                return false
            }
        },
        hasDefaultApplication: { path in
            OpenWithChoices.contentType(forPath: path)
                .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
        },
        chooseApplication: { path in
            let panel = NSOpenPanel()
            panel.title = String(localized: "选择应用")
            panel.message = String(localized: "选择用来打开「\((path as NSString).lastPathComponent)」的应用。之后同类文件会直接用它打开。")
            panel.prompt = String(localized: "打开")
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            return panel.runModal() == .OK ? panel.url : nil
        },
        uTableAvailable: { UTableHandoff.isAvailable },
        openInUTable: { hostID, remotePath in
            await UTableHandoff.open(hostID: hostID, remotePath: remotePath)
        },
        confirmOpenWhileInUse: { fileName, companions in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "\(RemoteName.isolated(fileName)) 可能正被远端程序使用")
            alert.informativeText = String(localized: """
                远端存在 \(companions.joined(separator: String(localized: "、", comment: "并列项之间的分隔符")))，说明有程序正在写这个数据库（或上次异常退出）。\
                uTable 会把整个库下载到本地，改动后再整体传回；如果远端程序同时在写，双方的改动会互相覆盖，\
                甚至损坏数据库。建议先停掉使用它的服务，或只做查看。
                """)
            alert.addButton(withTitle: String(localized: "仍然打开"))
            alert.addButton(withTitle: String(localized: "取消"))
            return alert.runModal() == .alertFirstButtonReturn
        },
        askConflict: { fileName in
            let alert = NSAlert()
            alert.messageText = String(localized: "远程文件已变化")
            alert.informativeText = String(localized: "\(RemoteName.isolated(fileName)) 在你打开之后被别处改过。上传会覆盖远程的这些改动。")
            alert.addButton(withTitle: String(localized: "覆盖远程文件"))
            alert.addButton(withTitle: String(localized: "放弃本地改动"))
            alert.addButton(withTitle: String(localized: "暂不上传"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:  return .keepMine
            case .alertSecondButtonReturn: return .useRemote
            default:                       return .cancel
            }
        },
        confirmStopSync: { fileName in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "停止同步 \(RemoteName.isolated(fileName))？")
            alert.informativeText = String(localized: "本地副本还有未上传到主机的改动，停止后不会再上传。")
            alert.addButton(withTitle: String(localized: "停止同步"))
            alert.addButton(withTitle: String(localized: "取消"))
            return alert.runModal() == .alertFirstButtonReturn
        },
        stagingRoot: FileManager.default.temporaryDirectory)
}

/// 远端文件的「打开」（见 `RemoteFileAction.open`）：数据库交给 uTable，其余下载到本地
/// 交给外部应用，并**监听本地副本，保存后自动传回远端**。
///
/// - 数据库（SQLite）：uTable 以远程 SQLite 模式直连，自动保存由它负责（见
///   `UTableHandoff`）。没装 / 版本太旧 / 主机带跳板机 / 文件头不是 SQLite 时退回下面那条路。
/// - 其他文件：下载到 0700 私有临时目录 → 用记住的应用 / 系统默认应用 / 让用户挑的应用打开
///   → 每秒看一次本地副本的指纹，外部应用存了盘就上传（`ExternalEditChangeDetector`）。
///   上传前比对远端 mtime，远端被别处改过就弹三选一，不静默覆盖。
///
/// 每个工作区窗口 / 每个独立 SFTP 标签一份。关窗与退出 app 前由
/// `ExternalEditCloseGuard` 检查还没上传的改动。
@MainActor
@Observable
final class ExternalOpenCoordinator {
    enum Route: Equatable {
        /// 「打开」：数据库优先 uTable，其余用记住的应用 → 系统默认应用 → 让用户挑。
        case preferred
        /// 「打开方式 ▸ uTable」。
        case uTable
        /// 「打开方式 ▸ 某个应用」。
        case application(URL)
        /// 「打开方式 ▸ 其他…」：让用户挑，并记住。
        case chooseApplication
    }

    enum SessionState: Equatable {
        case watching
        case uploading
        case failed(String)
    }

    struct Session: Identifiable {
        let id = UUID()
        let remotePath: String
        let localURL: URL
        /// 远端基线 mtime：下载完成 / 上一次上传成功后远端的修改时间。上传前远端 mtime
        /// 跟它对不上，说明远端被别处改过。
        var remoteModificationDate: Date
        var detector: ExternalEditChangeDetector
        var state: SessionState = .watching
        var fileName: String { (remotePath as NSString).lastPathComponent }

        var hasUnsyncedChanges: Bool {
            state == .uploading
                || detector.hasUnsyncedChanges(current: LocalFileFingerprint.read(localURL))
        }
    }

    struct Toast: Identifiable, Equatable {
        enum Kind: Equatable { case progress, success, info, failure }
        let id = UUID()
        let kind: Kind
        let title: String
        var detail: String?
        /// 失败时的「重试」（指向一个外部编辑会话）。
        var retrySessionID: UUID?
    }

    private(set) var sessions: [Session] = []
    private(set) var toasts: [Toast] = []

    private let provider: () -> (any SFTPProviding)?
    private let host: () -> ExternalOpenHost?
    private let preference: ExternalAppPreference
    private let system: ExternalOpenSystem
    private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var toastDismissTasks: [UUID: Task<Void, Never>] = [:]
    /// 正在下载的远端路径：连点两下不下两份。
    @ObservationIgnored private var inFlight: Set<RemoteNameKey> = []

    static let toastLifetime: Duration = .seconds(4)
    /// SFTP 的 mtime 只到秒，比对时留一秒余量。
    static let mtimeTolerance: TimeInterval = 1

    /// 进程里活着的全部实例（弱引用）——退出 app 前据此汇总没上传的改动。
    private static var live: [WeakBox] = []
    private struct WeakBox { weak var value: ExternalOpenCoordinator? }

    static var allLive: [ExternalOpenCoordinator] {
        live.removeAll { $0.value == nil }
        return live.compactMap(\.value)
    }

    init(provider: @escaping () -> (any SFTPProviding)?,
         host: @escaping () -> ExternalOpenHost?,
         preference: ExternalAppPreference = ExternalAppPreference(),
         system: ExternalOpenSystem = .live,
         pollInterval: Duration = .seconds(1)) {
        self.provider = provider
        self.host = host
        self.preference = preference
        self.system = system
        self.pollInterval = pollInterval
        Self.live.append(WeakBox(value: self))
    }

    /// 本地有没有还没传上去的改动（含正在上传的）。
    var unsyncedSessions: [Session] { sessions.filter(\.hasUnsyncedChanges) }

    // MARK: - 打开

    func open(remotePath: String, route: Route = .preferred) async {
        switch route {
        case .preferred:
            if SQLiteFileDetector.isCandidate(path: remotePath),
               await openInUTable(remotePath, explicit: false) { return }
            await openLocally(remotePath, application: .automatic)
        case .uTable:
            if await openInUTable(remotePath, explicit: true) { return }
            await openLocally(remotePath, application: .automatic)
        case .application(let url):
            preference.remember(url, forPath: remotePath)
            await openLocally(remotePath, application: .specific(url))
        case .chooseApplication:
            await openLocally(remotePath, application: .choose)
        }
    }

    /// 交给 uTable。返回 true 表示这次打开已经处理完（包括用户在警告里点了取消）；
    /// false 表示应当退回「下载到本地」。
    private func openInUTable(_ remotePath: String, explicit: Bool) async -> Bool {
        let name = (remotePath as NSString).lastPathComponent
        guard system.uTableAvailable() else {
            if explicit {
                showToast(.info, String(localized: "未找到可用的 uTable"),
                          detail: String(localized: "需要安装支持「从 uTerm 打开」的新版 uTable。已改为下载到本地打开。"))
            }
            return false
        }
        guard let host = host(), let sftp = provider() else {
            showToast(.failure, String(localized: "SFTP 尚未连接"),
                      detail: String(localized: "连接建立后再打开 \(RemoteName.isolated(name))。"))
            return true
        }
        guard !host.usesJumpHost else {
            showToast(.info, String(localized: "uTable 暂不支持跳板机"),
                      detail: String(localized: "\(host.name) 经跳板机连接，已改为下载到本地打开。"))
            return false
        }

        let prefix: Data
        do {
            prefix = try await sftp.readRange(remotePath, offset: 0,
                                              length: SQLiteFileDetector.header.count)
        } catch {
            showToast(.failure, String(localized: "打开失败：\(RemoteName.isolated(name))"), detail: FriendlyError.describe(error))
            return true
        }
        guard SQLiteFileDetector.hasSQLiteHeader(prefix) else {
            if explicit {
                showToast(.info, String(localized: "\(RemoteName.isolated(name)) 不是 SQLite 数据库"),
                          detail: String(localized: "已改为下载到本地打开。"))
            }
            return false
        }

        var companions: [String] = []
        for path in SQLiteFileDetector.companionPaths(for: remotePath) {
            if (try? await sftp.stat(path)) != nil {
                companions.append((path as NSString).lastPathComponent)
            }
        }
        if !companions.isEmpty, !system.confirmOpenWhileInUse(name, companions) {
            return true
        }

        guard await system.openInUTable(host.id, remotePath) else {
            showToast(.failure, String(localized: "无法启动 uTable"),
                      detail: String(localized: "已改为下载到本地打开。"))
            return false
        }
        return true
    }

    private enum ApplicationRequest {
        /// 记住的应用 → 系统默认应用 → 让用户挑。
        case automatic
        case specific(URL)
        case choose
    }

    /// 解析出具体用哪个应用：`.some(nil)` = 系统默认应用；`nil` = 用户取消。
    private func resolve(_ request: ApplicationRequest, forPath path: String) -> URL?? {
        switch request {
        case .specific(let url):
            return .some(url)
        case .automatic:
            if let remembered = preference.application(forPath: path) { return .some(remembered) }
            if system.hasDefaultApplication(path) { return .some(nil) }
            fallthrough
        case .choose:
            guard let chosen = system.chooseApplication(path) else { return nil }
            preference.remember(chosen, forPath: path)
            return .some(chosen)
        }
    }

    private func openLocally(_ remotePath: String, application request: ApplicationRequest) async {
        let name = (remotePath as NSString).lastPathComponent

        // 已经在外部编辑：直接再打开那份本地副本。重新下载会盖掉还没传上去的改动。
        if let existing = sessions.first(where: { $0.remotePath.remoteKey == remotePath.remoteKey }) {
            guard let application = resolve(request, forPath: remotePath) else { return }
            _ = await system.launch(existing.localURL, application)
            return
        }

        guard let sftp = provider() else {
            showToast(.failure, String(localized: "SFTP 尚未连接"),
                      detail: String(localized: "连接建立后再打开 \(RemoteName.isolated(name))。"))
            return
        }
        // 先挑应用再下载：用户在选择框里点了取消，就不白下一趟。
        guard let application = resolve(request, forPath: remotePath) else { return }
        guard inFlight.insert(remotePath.remoteKey).inserted else { return }
        defer { inFlight.remove(remotePath.remoteKey) }

        let progress = showToast(.progress, String(localized: "正在打开 \(RemoteName.isolated(name))…"), autoDismiss: false)
        defer { dismissToast(progress) }

        let destination: URL
        let remoteStat: RemoteStat
        do {
            remoteStat = try await sftp.stat(remotePath)
            destination = try ExternalFileStager.prepareDestination(
                suggestedName: name, rootDirectory: system.stagingRoot)
            // 流式落盘：走这条路的常是几百 MB 的归档 / 媒体，先读成 Data 会把整个文件搬进内存。
            try await sftp.download(remotePath: remotePath, toLocalURL: destination, onProgress: nil)
            try ExternalFileStager.restrictPermissions(at: destination)
        } catch {
            showToast(.failure, String(localized: "打开失败：\(RemoteName.isolated(name))"), detail: FriendlyError.describe(error))
            return
        }

        // 基线在启动应用**之前**取：打开即改写文件的应用（格式化、补换行）那一下也算改动。
        let baseline = LocalFileFingerprint.read(destination)
        guard await system.launch(destination, application) else {
            showToast(.failure, String(localized: "打开失败：\(RemoteName.isolated(name))"),
                      detail: String(localized: "没有应用能打开这个文件。"))
            return
        }
        sessions.append(Session(
            remotePath: remotePath,
            localURL: destination,
            remoteModificationDate: remoteStat.mtime,
            detector: ExternalEditChangeDetector(synced: baseline)))
        startPolling()
        showToast(.info, String(localized: "已打开 \(RemoteName.isolated(name))"),
                  detail: String(localized: "保存后自动上传回主机。"))
    }

    // MARK: - 监听与上传

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard let self, !self.sessions.isEmpty else { break }
                await self.pollNow()
            }
            self?.pollTask = nil
        }
    }

    /// 看一轮全部本地副本（轮询任务每个间隔调一次；测试直接调）。
    func pollNow() async {
        for id in sessions.map(\.id) {
            guard let index = index(of: id), sessions[index].state != .uploading else { continue }
            let current = LocalFileFingerprint.read(sessions[index].localURL)
            if case .upload(let fingerprint) = sessions[index].detector.observe(current) {
                await upload(id, fingerprint: fingerprint)
            }
        }
    }

    /// 关窗 / 退出前：不等「连续两次同指纹」，把所有没上传的改动立刻传上去。
    /// 返回是否全部成功（冲突被用户暂缓也算没成功）。
    func flushPendingUploads() async -> Bool {
        for id in sessions.map(\.id) {
            guard let session = session(id), session.state != .uploading,
                  let current = LocalFileFingerprint.read(session.localURL),
                  session.detector.hasUnsyncedChanges(current: current) else { continue }
            update(id) { $0.detector.clearPostponed() }
            await upload(id, fingerprint: current)
        }
        return unsyncedSessions.isEmpty
    }

    private func upload(_ id: UUID, fingerprint: LocalFileFingerprint, overwriteRemote: Bool = false) async {
        guard let session = session(id) else { return }
        guard let sftp = provider() else {
            fail(id, fingerprint: fingerprint, message: String(localized: "SFTP 尚未连接"))
            return
        }
        update(id) { $0.state = .uploading }

        if !overwriteRemote,
           let remote = try? await sftp.stat(session.remotePath),
           abs(remote.mtime.timeIntervalSince(session.remoteModificationDate)) > Self.mtimeTolerance {
            update(id) { $0.state = .watching }
            switch system.askConflict(session.fileName) {
            case .keepMine:
                await upload(id, fingerprint: fingerprint, overwriteRemote: true)
            case .useRemote:
                await replaceLocalWithRemote(id)
            case .cancel:
                update(id) { $0.detector.postpone(fingerprint) }
            }
            return
        }

        do {
            try await sftp.upload(localURL: session.localURL, toRemotePath: session.remotePath,
                                  onProgress: nil)
            let remoteDate = (try? await sftp.stat(session.remotePath))?.mtime ?? Date()
            update(id) {
                $0.detector.markSynced(fingerprint)
                $0.remoteModificationDate = remoteDate
                $0.state = .watching
            }
            dismissToasts(retrying: id)
            let target = host().map { "\($0.name):\(session.remotePath)" } ?? session.remotePath
            showToast(.success, String(localized: "已上传 \(session.fileName)"), detail: target)
        } catch {
            fail(id, fingerprint: fingerprint, message: FriendlyError.describe(error))
        }
    }

    private func fail(_ id: UUID, fingerprint: LocalFileFingerprint, message: String) {
        update(id) {
            $0.detector.postpone(fingerprint)
            $0.state = .failed(message)
        }
        guard let session = session(id) else { return }
        dismissToasts(retrying: id)
        var toast = Toast(kind: .failure,
                          title: String(localized: "上传失败：\(session.fileName)"), detail: message)
        toast.retrySessionID = id
        push(toast, autoDismiss: false)
    }

    /// 用远端内容覆盖本地副本（外部应用多半会提示「文件已在别处更改」并重新载入）。
    private func replaceLocalWithRemote(_ id: UUID) async {
        guard let session = session(id), let sftp = provider() else { return }
        do {
            let remote = try await sftp.stat(session.remotePath)
            try await sftp.download(remotePath: session.remotePath, toLocalURL: session.localURL,
                                    onProgress: nil)
            try ExternalFileStager.restrictPermissions(at: session.localURL)
            let fingerprint = LocalFileFingerprint.read(session.localURL)
            update(id) {
                if let fingerprint { $0.detector.markSynced(fingerprint) }
                $0.remoteModificationDate = remote.mtime
                $0.state = .watching
            }
            showToast(.info, String(localized: "已用远程版本覆盖本地 \(session.fileName)"))
        } catch {
            showToast(.failure, String(localized: "拉取远程版本失败：\(session.fileName)"),
                      detail: FriendlyError.describe(error))
        }
    }

    // MARK: - 会话操作（同步芯片 / toast 按钮）

    func retry(_ id: UUID) {
        guard let session = session(id), let fingerprint = LocalFileFingerprint.read(session.localURL)
        else { return }
        update(id) { $0.detector.clearPostponed() }
        Task { await upload(id, fingerprint: fingerprint) }
    }

    func stopSync(_ id: UUID) {
        guard let session = session(id) else { return }
        if session.hasUnsyncedChanges, !system.confirmStopSync(session.fileName) { return }
        sessions.removeAll { $0.id == id }
        dismissToasts(retrying: id)
    }

    func revealInFinder(_ id: UUID) {
        guard let session = session(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([session.localURL])
    }

    /// 窗口关闭：停止监听。本地副本留在私有临时目录里，由系统定期清理。
    func dispose() {
        pollTask?.cancel()
        pollTask = nil
        sessions.removeAll()
        toastDismissTasks.values.forEach { $0.cancel() }
        toastDismissTasks.removeAll()
        toasts.removeAll()
        Self.live.removeAll { $0.value == nil || $0.value === self }
    }

    // MARK: - Toast

    @discardableResult
    private func showToast(_ kind: Toast.Kind, _ title: String, detail: String? = nil,
                           autoDismiss: Bool = true) -> UUID {
        push(Toast(kind: kind, title: title, detail: detail), autoDismiss: autoDismiss)
    }

    @discardableResult
    private func push(_ toast: Toast, autoDismiss: Bool) -> UUID {
        toasts.append(toast)
        // 最多叠 4 条，旧的先走。
        while toasts.count > 4 { dismissToast(toasts[0].id) }
        if autoDismiss {
            toastDismissTasks[toast.id] = Task { [weak self] in
                try? await Task.sleep(for: Self.toastLifetime)
                guard !Task.isCancelled else { return }
                self?.dismissToast(toast.id)
            }
        }
        return toast.id
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        toastDismissTasks.removeValue(forKey: id)?.cancel()
    }

    private func dismissToasts(retrying sessionID: UUID) {
        for toast in toasts where toast.retrySessionID == sessionID { dismissToast(toast.id) }
    }

    // MARK: - Helpers

    private func index(of id: UUID) -> Int? { sessions.firstIndex { $0.id == id } }
    private func session(_ id: UUID) -> Session? { index(of: id).map { sessions[$0] } }
    private func update(_ id: UUID, _ body: (inout Session) -> Void) {
        guard let index = index(of: id) else { return }
        body(&sessions[index])
    }
}
