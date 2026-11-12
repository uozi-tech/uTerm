import SwiftUI
import SwiftData
import Observation

/// iOS 文件标签的控制器：浏览状态机是两端共享的 `FileBrowserModel`（建连、目录加载代次、
/// 符号链接解析、增删改、递归删除进度、错误呈现、断线自动重连、看门狗探测都在那里），
/// 这里只把它转成 iOS 视图绑定的名字（`state` / `path` / `entries` / `loading` …）、把操作单的
/// 调用包成发射后不管，并保留 iOS 自己的下载落盘（`ExternalFileStager` → 系统分享面板）。
///
/// 与 macOS 的有意差异是 `FileBrowserModel` 的参数：排序固定（目录在前、名字升序、显示点文件），
/// 不补属主名。
@MainActor
@Observable
final class MobileSFTPController {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    /// 浏览状态机本体（两端共享）。
    let browser: FileBrowserModel

    var state: State {
        // 远程 Mac：连上并问到主目录之前，浏览器本体还没东西可看。
        if let remotePhase { return remotePhase }
        switch browser.state {
        case .idle: return .idle
        case .connecting: return .connecting
        case .browsing: return .connected
        case .failed(let message): return .failed(message)
        }
    }
    var path: String { browser.currentPath }
    /// 已按 `sortOptions` 排好的当前目录。
    var entries: [RemoteEntry] { browser.sortedEntries }
    var loading: Bool { browser.isLoading }
    /// 单次操作（打开目录 / 删除 / 改名 / chmod / 上传 / 下载）失败的提示。
    /// 只有连接本身断了（且重连不上）才把 `state` 翻成 `.failed`；其余失败浏览照常。
    var transientError: String? { browser.transientError }
    /// 正在进行的递归删除；nil = 无。同一时刻只允许一个。
    var deletion: RemoteDeletionProgress? { browser.deletion }

    /// 浏览的是一台配对过的 Mac（文件走远控链路，不建 SSH）。主机的文件标签为 nil。
    @ObservationIgnored let remoteMac: RemoteMacClient?
    @ObservationIgnored private var remoteProvider: RemoteMacFileProvider?
    /// 远程 Mac 还没进到浏览态时的状态（连接中 / 失败）；nil = 看浏览器本体的。
    private var remotePhase: State?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// 本控制器下载落盘的根目录（每次下载由 `ExternalFileStager` 在其下建一个独立的
    /// 0700 子目录，关标签时整个删掉）。
    @ObservationIgnored private let downloadRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("sftp-downloads", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// 记下首次建连参数，供失败后 `restart()`（连接中页「重试」）重连。
    @ObservationIgnored private var lastProfile: ServerProfile?
    @ObservationIgnored private var lastContainer: ModelContainer?
    @ObservationIgnored private var lastRelay: HostKeyChallengeRelay?

    /// iOS 列表的固定排序：目录在前、名字升序（与 macOS 同一套 `RemoteEntrySort` 规则，
    /// Finder 式比较，`f2` 在 `f10` 前），**显示点文件**——手机上没有「显示隐藏文件」开关，
    /// 滤掉的话 `.ssh` / `.bashrc` 就没有入口了。
    nonisolated static let sortOptions = RemoteEntrySortOptions(
        key: .name, ascending: true, foldersFirst: true, showHidden: true)

    init() {
        remoteMac = nil
        browser = FileBrowserModel(sortOptions: Self.sortOptions, resolvesOwnerNames: false)
    }

    /// 浏览一台配对过的 Mac。连接归远控链路管（和它的终端标签共用一条），这里只等它连上、问到主目录。
    /// 建好后调 `startRemote()`。
    init(remoteMac client: RemoteMacClient) {
        let provider = RemoteMacFileProvider(client: client)
        remoteMac = client
        remoteProvider = provider
        browser = FileBrowserModel(provider: provider, startPath: "/", sortOptions: Self.sortOptions)
        remotePhase = .connecting
        started = true     // 误触的 `start(profile:…)` 不会去建 SSH 连接
    }

    /// 测试注入口（同 `FileBrowserModel.init(testProvider:startPath:)`）：
    /// 直接进入「已连上、当前目录 = `startPath`」的浏览态，不建任何真实连接。
    /// `started = true` 让误触的 `start(...)` 变成 no-op，绝不会回退到真实建连。
    ///
    /// 目录内容不在这里读 —— `entries` 仍由 `load(_:)` 走 provider 填，
    /// 这样测试跑的是产品自己的加载/排序路径。
    init(testProvider: any SFTPProviding, startPath: String) {
        remoteMac = nil
        browser = FileBrowserModel(testProvider: testProvider, startPath: startPath,
                                   sortOptions: Self.sortOptions, resolvesOwnerNames: false)
        started = true
    }

    static func markConnected(_ pid: PersistentIdentifier, in container: ModelContainer) {
        let ctx = container.mainContext
        if let profile = ctx.model(for: pid) as? ServerProfile {
            profile.lastConnectedAt = Date()
            try? ctx.save()
        }
    }

    func start(profile: ServerProfile, container: ModelContainer, relay: HostKeyChallengeRelay) {
        guard !started else { return }
        started = true
        lastProfile = profile; lastContainer = container; lastRelay = relay
        let pid = profile.persistentModelID
        let browser = browser
        // 只弱引用自己：握手最长要等到登录超时，不能让已关掉的标签被这段等待拖住。
        // 关标签时 `browser.dispose()` 让在途建连落地后直接关掉会话。
        connectTask = Task { [weak self] in
            await browser.connect(profile: profile, modelContainer: container, hostKeyRelay: relay)
            guard let self, !self.closed, browser.state == .browsing else { return }
            Self.markConnected(pid, in: container)
        }
    }

    /// 远程 Mac：连上 → 问主目录 → 列第一屏。失败停在失败页，`restart()` 再来。
    func startRemote() {
        guard let client = remoteMac, let provider = remoteProvider, !closed else { return }
        connectTask?.cancel()
        remotePhase = .connecting
        let browser = browser
        connectTask = Task { [weak self] in
            await client.connect()
            guard let self, !self.closed, !Task.isCancelled else { return }
            switch client.state {
            case .connected:
                break
            case .failed(let message):
                self.remotePhase = .failed(message)
                return
            case .awaitingApproval:
                self.remotePhase = .failed(String(localized: "还在等那台 Mac 上确认配对。在 Mac 上点「允许」后重试。"))
                return
            case .idle, .connecting:
                self.remotePhase = .failed(String(localized: "连不上这台 Mac"))
                return
            }
            do {
                // 那台 Mac 关着「允许打开本机终端」、或它的 uTerm 太旧，这一步就会说清楚。
                let home = try await provider.realPath("~")
                guard !self.closed, !Task.isCancelled else { return }
                await browser.load(home)
                guard !self.closed, !Task.isCancelled else { return }
                self.remotePhase = nil
            } catch {
                guard !self.closed else { return }
                self.remotePhase = .failed(error.localizedDescription)
            }
        }
    }

    func load(_ target: String) async { await browser.load(target) }

    /// 清除一次性错误（绑定到错误提示的关闭）。
    func clearTransientError() { browser.clearTransientError() }

    /// 进目录。符号链接先解析（见 `openSymlink`）：指向目录才进，指向文件什么也不做——
    /// 要按文件处理（弹操作单）的调用方直接用 `openSymlink` 的返回值。
    func open(_ entry: RemoteEntry) {
        if entry.isSymlink {
            Task { _ = await openSymlink(entry) }
            return
        }
        guard entry.isDirectory else { return }
        let next = RemotePath.join(path, entry.name)
        Task { await browser.load(next) }
    }

    /// 点符号链接：沿链接探测。指向目录 → 进入，返回 false；
    /// 指向文件（或目标不存在）→ 不动当前列表，返回 true，调用方按文件处理。
    func openSymlink(_ entry: RemoteEntry, in directory: String? = nil) async -> Bool {
        await browser.resolveSymlinkForOpen(entry, in: directory) != nil
    }

    func goUp() {
        guard path != "/" else { return }
        let parent = RemotePath.parent(of: path)
        Task { await browser.load(parent) }
    }

    func refresh() { Task { await browser.refresh() } }

    /// `directory` 是条目所在目录。操作单从长按到确认之间隔着动画与确认框，
    /// 这期间当前目录可能已经换了——调用方应传长按那一刻的目录（见 `FilesSessionBody`），
    /// 不传则取当前目录。进度 / 「正在删除」提示在调用这一刻就落地。
    func delete(_ entry: RemoteEntry, in directory: String? = nil) {
        browser.beginDelete(entry, in: directory)
    }

    /// 请求中止正在进行的递归删除。已经删掉的部分不会回滚（SFTP 没有事务）。
    func cancelDeletion() { browser.cancelDeletion() }

    func close() {
        closed = true
        connectTask?.cancel()
        connectTask = nil
        browser.dispose()
        try? FileManager.default.removeItem(at: downloadRoot)
    }

    /// 失败后重连（连接中页「重试」）；只有处于失败态时才生效。
    func restart() {
        if remoteMac != nil {
            guard case .failed = state else { return }
            browser.clearTransientError()
            startRemote()
            return
        }
        guard case .failed = state,
              let profile = lastProfile, let container = lastContainer, let relay = lastRelay else { return }
        connectTask?.cancel()
        browser.clearTransientError()
        started = false
        start(profile: profile, container: container, relay: relay)
    }

    // MARK: - 文件操作（设计稿 FileActionSheet / PermissionSheet）

    /// 当前目录下某条目的完整远程路径。
    func fullPath(_ entry: RemoteEntry) -> String { RemotePath.join(path, entry.name) }

    /// 改权限（真实 chmod，经 Citadel setAttributes，仅 9 位 POSIX 位）。
    func chmod(_ entry: RemoteEntry, mode: UInt32, in directory: String? = nil) {
        let dir = directory ?? path
        Task { await browser.setPermissions(entry: entry, mode: mode, recursive: false, in: dir) }
    }

    /// 重命名（同目录内移动）。名字去首尾空白；空名或没变不发请求。
    func rename(_ entry: RemoteEntry, to newName: String, in directory: String? = nil) {
        guard RemoteFileOperations.validatedNewName(newName, for: entry) != nil else { return }
        let dir = directory ?? path
        Task { await browser.rename(entry: entry, to: newName, in: dir) }
    }

    /// 流式下载到临时文件，返回本地 URL（供系统分享面板使用）。
    ///
    /// 落盘路径与 macOS「外部打开」同一套（`ExternalFileStager`）：每次下载一个独立的
    /// 0700 随机目录、文件名清洗、落盘后收紧到 0600。两个标签同时下同名文件
    /// （如 `nginx.conf`）时互不覆盖，远端给的怪名字（含 `/`、控制字符）也落不到别处。
    /// 字节经 `SFTPSession` 的固定缓冲流式落盘，不在内存里攒整个文件、也不在主线程写盘。
    func download(_ entry: RemoteEntry, in directory: String? = nil) async -> URL? {
        guard let session = browser.sftpProvider else { return nil }
        let full = RemotePath.join(directory ?? path, entry.name)
        var destination: URL?
        do {
            let url = try ExternalFileStager.prepareDestination(
                suggestedName: entry.name, rootDirectory: downloadRoot)
            destination = url
            try await session.download(remotePath: full, toLocalURL: url, onProgress: nil)
            try ExternalFileStager.restrictPermissions(at: url)
            return url
        } catch {
            if let destination {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            }
            browser.report(error, action: "下载")
            return nil
        }
    }

    /// 从本地文件流式上传到当前目录（不先把整个文件读进内存）。
    func upload(from url: URL) {
        let dir = path
        Task { await browser.upload(localURL: url, in: dir) }
    }

    /// 会话是否还开着（标签关掉后，晚到的下载不应再弹分享面板）。
    var isOpen: Bool { !closed && browser.sftpProvider != nil }
}
