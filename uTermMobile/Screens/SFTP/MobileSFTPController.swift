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

    /// 当前会话。生产是 `SFTPSession`，测试是任意 `SFTPProviding` 实现。
    @ObservationIgnored private var session: (any SFTPProviding)?
    @ObservationIgnored private var started = false
    /// 目录加载代次：每次 `load` 递增，晚到的旧结果直接丢弃。否则网速慢时先点 A 再点 B，
    /// A 后返回会把列表和路径改回 A；`loading` 也会被先返回的那次提前置掉。
    @ObservationIgnored private var loadGeneration = 0
    /// 建连代次：`close()` / `restart()` 递增，在途建连落地时对不上就关掉刚建的会话。
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// 本控制器下载落盘的目录（每次下载一个独立子目录，关标签时整个删掉）。
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
            state = .failed(error.localizedDescription)
        }
        loading = false
    }

    /// 目录在前、名字按本地化大小写无关排序。大目录（上万条）要做几十万次本地化比较，
    /// 放在并发线程池里，不占主线程。
    @concurrent nonisolated private static func sortedEntries(_ list: [RemoteEntry]) async -> [RemoteEntry] {
        list.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// 重新列当前目录（增删改之后）。
    private func reload() async { await load(path) }

    func open(_ entry: RemoteEntry) {
        guard entry.isDirectory || entry.isSymlink else { return }
        let next = joined(path, entry.name)
        Task { await load(next) }
    }

    func goUp() {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        Task { await load(parent.isEmpty ? "/" : parent) }
    }

    func refresh() { Task { await reload() } }

    /// `directory` 是条目所在目录。操作单从长按到确认之间隔着动画与确认框，
    /// 这期间当前目录可能已经换了——调用方应传长按那一刻的目录（见 `FilesSessionBody`），
    /// 不传则取当前目录。
    func delete(_ entry: RemoteEntry, in directory: String? = nil) {
        guard let session else { return }
        let full = joined(directory ?? path, entry.name)
        Task { [weak self] in
            do {
                if entry.isDirectory { try await session.removeDirectory(full) }
                else { try await session.removeFile(full) }
                await self?.reload()
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func close() {
        connectGeneration &+= 1
        loadGeneration &+= 1
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
        started = false
        state = .idle
        start(profile: profile, container: container, relay: relay)
    }

    // MARK: - 文件操作（设计稿 FileActionSheet / PermissionSheet）

    /// 当前目录下某条目的完整远程路径。
    func fullPath(_ entry: RemoteEntry) -> String { joined(path, entry.name) }

    /// 改权限（真实 chmod，经 Citadel setAttributes，仅 9 位 POSIX 位）。
    func chmod(_ entry: RemoteEntry, mode: UInt32, in directory: String? = nil) {
        guard let session else { return }
        let full = joined(directory ?? path, entry.name)
        Task { [weak self] in
            do {
                try await session.setPermissions(path: full, mode: mode & 0o777)
                await self?.reload()
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// 重命名（同目录内移动）。
    func rename(_ entry: RemoteEntry, to newName: String, in directory: String? = nil) {
        guard let session else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        let dir = directory ?? path
        let from = joined(dir, entry.name)
        let to = joined(dir, trimmed)
        Task { [weak self] in
            do {
                try await session.rename(from, to: to)
                await self?.reload()
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// 流式下载到临时文件，返回本地 URL（供系统分享面板使用）。
    ///
    /// 每次下载一个独立子目录：两个标签同时下同名文件（如 `nginx.conf`）时互不覆盖。
    /// 字节经 `SFTPSession` 的固定缓冲流式落盘，不在内存里攒整个文件、也不在主线程写盘。
    func download(_ entry: RemoteEntry, in directory: String? = nil) async -> URL? {
        guard let session else { return nil }
        let full = joined(directory ?? path, entry.name)
        let folder = downloadRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(entry.name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await session.download(remotePath: full, toLocalURL: url, onProgress: nil)
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if self.session != nil { state = .failed(error.localizedDescription) }
            return nil
        }
    }

    /// 从本地文件流式上传到当前目录（不先把整个文件读进内存）。
    func upload(from url: URL) {
        guard let session else { return }
        let dest = joined(path, url.lastPathComponent)
        Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await session.upload(localURL: url, toRemotePath: dest, onProgress: nil)
                await self?.reload()
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// 会话是否还开着（标签关掉后，晚到的下载不应再弹分享面板）。
    var isOpen: Bool { session != nil }

    private func joined(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
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
