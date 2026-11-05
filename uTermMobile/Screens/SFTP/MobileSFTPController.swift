import SwiftUI
import SwiftData
import Observation

/// iOS SFTP 浏览控制器：在一台主机上建连，之后所有操作都经 `SFTPProviding`。
///
/// 生产路径（`start(profile:container:relay:)`）建的仍是真实 Citadel `SFTPSession`；
/// 依赖只声明到协议上，是为了让测试能注入假会话 —— 与桌面 `FileBrowserModel`
/// 的 `init(testProvider:startPath:)` 同一条缝、同一个协议。
@MainActor
@Observable
final class MobileSFTPController {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    var state: State = .idle
    var path: String = "/"
    var entries: [RemoteEntry] = []
    var loading = false
    /// 单次操作（打开目录 / 删除 / 改名 / chmod / 上传 / 下载）失败的提示。
    /// 只有连接本身断了才把 `state` 翻成 `.failed`；其余失败浏览照常，视图弹一个
    /// 「操作失败」提示（对齐 macOS `FileBrowserModel.transientError`）。
    private(set) var transientError: String?
    /// 正在进行的递归删除；nil = 无。同一时刻只允许一个（见 `delete`）。
    private(set) var deletion: RemoteDeletionProgress?
    /// 取消旗标：`cancelDeletion()` / `close()` 置位，删除循环在每次往返前检查。
    @ObservationIgnored private var deletionCancelled = false

    /// 当前会话。生产是 `SFTPSession`，测试是任意 `SFTPProviding` 实现。
    @ObservationIgnored private var session: (any SFTPProviding)?
    @ObservationIgnored private var started = false
    /// 目录加载代次：每次 `load` 递增，晚到的旧结果直接丢弃。否则网速慢时先点 A 再点 B，
    /// A 后返回会把列表和路径改回 A；`loading` 也会被先返回的那次提前置掉。
    @ObservationIgnored private var loadGeneration = 0
    /// 建连代次：`close()` / `restart()` 递增，在途建连落地时对不上就关掉刚建的会话。
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// 本控制器下载落盘的根目录（每次下载由 `ExternalFileStager` 在其下建一个独立的
    /// 0700 子目录，关标签时整个删掉）。
    @ObservationIgnored private let downloadRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("sftp-downloads", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    init() {}

    /// 测试注入口（镜像 `FileBrowserModel.init(testProvider:startPath:)`）：
    /// 直接进入「已连上、当前目录 = `startPath`」的浏览态，不建任何真实连接。
    /// `started = true` 让误触的 `start(...)` 变成 no-op，绝不会回退到真实建连。
    ///
    /// 目录内容不在这里读 —— `entries` 仍由 `load(_:)` 走 provider 填，
    /// 这样测试跑的是产品自己的加载/排序路径。
    init(testProvider: any SFTPProviding, startPath: String) {
        self.session = testProvider
        self.state = .connected
        self.path = startPath
        self.started = true
    }

    /// 记下首次建连参数，供失败后 `restart()`（连接中页「重试」）重连。
    @ObservationIgnored private var lastProfile: ServerProfile?
    @ObservationIgnored private var lastContainer: ModelContainer?
    @ObservationIgnored private var lastRelay: HostKeyChallengeRelay?

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
        state = .connecting
        lastProfile = profile; lastContainer = container; lastRelay = relay
        connectGeneration &+= 1
        let attempt = connectGeneration

        let snapshot = SSHConnection.ProfileSnapshot(profile)
        let lookup = SSHAuthResolver.Lookup(profile)
        let jumpLookup = profile.jumpHost.map { SSHAuthResolver.Lookup($0) }
        let verifier = HostKeyVerifier(modelContainer: container)
        let pid = profile.persistentModelID
        let approver = relay.makeApprover()

        // 全程弱引用：握手最长要等到登录超时，不能让已关掉的标签被这段等待拖住。
        connectTask = Task { [weak self] in
            let resolved: (auth: ResolvedAuth, jump: ResolvedAuth?)
            do {
                // 钥匙串读取（3~5 次 SecItem IPC）离开主线程。
                resolved = try await SSHAuthResolver.resolveOffMain(lookup, jump: jumpLookup)
            } catch {
                self?.failConnect("认证材料解析失败：\(error.localizedDescription)", attempt: attempt)
                return
            }
            do {
                let connected = try await SSHClientFactory.connect(
                    profile: snapshot, auth: resolved.auth, jumpHostAuth: resolved.jump,
                    hostKeyVerifier: verifier, hostKeyApprover: approver)
                let session: any SFTPProviding = try await SFTPSession(connected: connected)
                let home = (try? await session.realPath(".")) ?? "/"
                // 建连期间标签被关 / 被重连取代：这条会话没人要了，关掉而不是挂在那里。
                guard let self, self.connectGeneration == attempt else {
                    await session.close()
                    return
                }
                self.session = session
                self.state = .connected
                self.path = home
                Self.markConnected(pid, in: container)
                ConnectionWatchdog.shared.register(self)
                await self.load(home)
            } catch {
                self?.failConnect(error.localizedDescription, attempt: attempt)
            }
        }
    }

    private func failConnect(_ message: String, attempt: Int) {
        guard connectGeneration == attempt else { return }
        state = .failed(message)
    }

    func load(_ target: String) async {
        guard let session else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        do {
            let list = try await session.list(path: target)
            let sorted = await Self.sortedEntries(list)
            guard generation == loadGeneration else { return }
            entries = sorted
            path = target
        } catch {
            guard generation == loadGeneration else { return }
            loading = false
            report(error, action: "打开目录")
            return
        }
        loading = false
    }

    /// 把一次操作失败落到状态上：连接已死 → `.failed`（连接中页给「重试」）；
    /// 其余（权限不足、文件不存在……）→ `transientError`，标签继续可浏览。
    private func report(_ error: Error, action: String) {
        guard session != nil else { return }   // 标签已关：晚到的失败没人看
        if SSHTransportFailure.isTransportFailure(error) {
            state = .failed(FriendlyError.describe(error))
        } else {
            transientError = "\(action)失败：\(FriendlyError.describe(error))"
        }
    }

    /// 清除一次性错误（绑定到错误提示的关闭）。
    func clearTransientError() { transientError = nil }

    /// iOS 列表的固定排序：目录在前、名字升序（与 macOS 同一套 `RemoteEntrySort` 规则，
    /// Finder 式比较，`f2` 在 `f10` 前），**显示点文件**——手机上没有「显示隐藏文件」开关，
    /// 滤掉的话 `.ssh` / `.bashrc` 就没有入口了。
    nonisolated static let sortOptions = RemoteEntrySortOptions(
        key: .name, ascending: true, foldersFirst: true, showHidden: true)

    /// 大目录（上万条）要做几十万次本地化比较，放在并发线程池里，不占主线程。
    @concurrent nonisolated private static func sortedEntries(_ list: [RemoteEntry]) async -> [RemoteEntry] {
        RemoteEntrySort.sorted(list, options: sortOptions)
    }

    /// 重新列当前目录（增删改之后）。
    private func reload() async { await load(path) }

    /// 进目录。符号链接先解析（见 `openSymlink`）：指向目录才进，指向文件什么也不做——
    /// 要按文件处理（弹操作单）的调用方直接用 `openSymlink` 的返回值。
    func open(_ entry: RemoteEntry) {
        if entry.isSymlink {
            Task { _ = await openSymlink(entry) }
            return
        }
        guard entry.isDirectory else { return }
        let next = RemotePath.join(path, entry.name)
        Task { await load(next) }
    }

    /// 点符号链接：沿链接探测（共享的 `RemoteFileOperations.resolveSymlink`）。
    /// 指向目录 → 进入（复用探测到的列表，省一次往返），返回 false；
    /// 指向文件（或目标不存在）→ 不动当前列表，返回 true，调用方按文件处理。
    ///
    /// 与 `load` 共用加载代次：解析期间用户又点了别的目录，晚到的结果直接丢弃。
    func openSymlink(_ entry: RemoteEntry, in directory: String? = nil) async -> Bool {
        guard let session, entry.isSymlink else { return false }
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        let target = await RemoteFileOperations.resolveSymlink(
            entry, in: directory ?? path, provider: session)
        guard generation == loadGeneration else { return false }
        switch target {
        case .directory(let linkPath, let listed):
            let sorted = await Self.sortedEntries(listed)
            guard generation == loadGeneration else { return false }
            entries = sorted
            path = linkPath
            loading = false
            return false
        case .file:
            loading = false
            return true
        }
    }

    func goUp() {
        guard path != "/" else { return }
        let parent = RemotePath.parent(of: path)
        Task { await load(parent) }
    }

    func refresh() { Task { await reload() } }

    /// `directory` 是条目所在目录。操作单从长按到确认之间隔着动画与确认框，
    /// 这期间当前目录可能已经换了——调用方应传长按那一刻的目录（见 `FilesSessionBody`），
    /// 不传则取当前目录。
    ///
    /// 目录递归删（共享的 `RemoteFileOperations`：先枚举整棵子树再逐项删），进度写进
    /// `deletion` 驱动删除提示，可中途 `cancelDeletion()`。同一时刻只跑一个删除任务，
    /// 第二次请求给出提示而不是静默吞掉。无论成功 / 失败 / 取消都重列目录——
    /// 失败或取消时远端多半已被删掉一部分。
    func delete(_ entry: RemoteEntry, in directory: String? = nil) {
        guard let session else { return }
        if let running = deletion {
            transientError = "正在删除「\(running.name)」，请等它结束后再删下一项。"
            return
        }
        let dir = directory ?? path
        if entry.isDirectory {
            deletionCancelled = false
            deletion = .starting(entry.name)
        }
        Task { [weak self] in
            var failure: Error?
            do {
                try await RemoteFileOperations.delete(
                    entry, in: dir, provider: session,
                    isCancelled: { self?.deletionCancelled ?? true },
                    onProgress: { self?.deletion?.apply($0) })
            } catch is RemoteFileOperations.DeletionCancelled {
                // 用户主动取消：不是错误，只把已删掉的部分刷出来。
            } catch {
                failure = error
            }
            guard let self else { return }
            self.deletion = nil
            await self.reload()
            if let failure { self.report(failure, action: "删除") }
        }
    }

    /// 请求中止正在进行的递归删除。已经删掉的部分不会回滚（SFTP 没有事务）。
    func cancelDeletion() {
        guard deletion != nil, !deletionCancelled else { return }
        deletionCancelled = true
        deletion?.isCancelling = true
    }

    func close() {
        connectGeneration &+= 1
        loadGeneration &+= 1
        deletionCancelled = true
        connectTask?.cancel()
        connectTask = nil
        let s = session
        Task { await s?.close() }
        session = nil
        try? FileManager.default.removeItem(at: downloadRoot)
    }

    /// 失败后重连（连接中页「重试」）；只有处于失败态时才生效。
    func restart() {
        guard case .failed = state,
              let profile = lastProfile, let container = lastContainer, let relay = lastRelay else { return }
        close()
        entries = []
        path = "/"
        transientError = nil
        started = false
        state = .idle
        start(profile: profile, container: container, relay: relay)
    }

    // MARK: - 文件操作（设计稿 FileActionSheet / PermissionSheet）

    /// 当前目录下某条目的完整远程路径。
    func fullPath(_ entry: RemoteEntry) -> String { RemotePath.join(path, entry.name) }

    /// 改权限（真实 chmod，经 Citadel setAttributes，仅 9 位 POSIX 位）。
    func chmod(_ entry: RemoteEntry, mode: UInt32, in directory: String? = nil) {
        guard let session else { return }
        let dir = directory ?? path
        Task { [weak self] in
            do {
                try await RemoteFileOperations.setPermissions(
                    entry, in: dir, mode: mode, provider: session)
                await self?.reload()
            } catch {
                self?.report(error, action: "权限设置")
            }
        }
    }

    /// 重命名（同目录内移动）。名字去首尾空白；空名或没变不发请求。
    func rename(_ entry: RemoteEntry, to newName: String, in directory: String? = nil) {
        guard let session,
              RemoteFileOperations.validatedNewName(newName, for: entry) != nil else { return }
        let dir = directory ?? path
        Task { [weak self] in
            do {
                try await RemoteFileOperations.rename(entry, to: newName, in: dir, provider: session)
                await self?.reload()
            } catch {
                self?.report(error, action: "重命名")
            }
        }
    }

    /// 流式下载到临时文件，返回本地 URL（供系统分享面板使用）。
    ///
    /// 落盘路径与 macOS「外部打开」同一套（`ExternalFileStager`）：每次下载一个独立的
    /// 0700 随机目录、文件名清洗、落盘后收紧到 0600。两个标签同时下同名文件
    /// （如 `nginx.conf`）时互不覆盖，远端给的怪名字（含 `/`、控制字符）也落不到别处。
    /// 字节经 `SFTPSession` 的固定缓冲流式落盘，不在内存里攒整个文件、也不在主线程写盘。
    func download(_ entry: RemoteEntry, in directory: String? = nil) async -> URL? {
        guard let session else { return nil }
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
            report(error, action: "下载")
            return nil
        }
    }

    /// 从本地文件流式上传到当前目录（不先把整个文件读进内存）。
    func upload(from url: URL) {
        guard let session else { return }
        let dest = RemotePath.join(path, url.lastPathComponent)
        Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await session.upload(localURL: url, toRemotePath: dest, onProgress: nil)
                await self?.reload()
            } catch {
                self?.report(error, action: "上传")
            }
        }
    }

    /// 会话是否还开着（标签关掉后，晚到的下载不应再弹分享面板）。
    var isOpen: Bool { session != nil }
}

extension MobileSFTPController: ConnectionHealthProbing {
    /// 连接判死（会话自己会强制关掉底层连接）时转成失败态，连接中页 / 失败页给出「重试」。
    func probeConnectionHealth() async {
        guard state == .connected, let session else { return }
        let alive = await session.verifyConnectionAlive()
        guard !alive, self.session === session else { return }
        state = .failed("连接已断开")
    }
}
