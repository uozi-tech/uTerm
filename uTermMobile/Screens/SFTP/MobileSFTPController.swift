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

        let snapshot = SSHConnection.ProfileSnapshot(profile)
        let keychain = KeychainStore()
        let auth: ResolvedAuth
        do { auth = try SSHAuthResolver.resolve(profile: profile, keychain: keychain) }
        catch { state = .failed("认证材料解析失败：\(error.localizedDescription)"); return }
        var jumpAuth: ResolvedAuth?
        if let jump = profile.jumpHost { jumpAuth = try? SSHAuthResolver.resolve(profile: jump, keychain: keychain) }
        let verifier = HostKeyVerifier(modelContainer: container)
        let pid = profile.persistentModelID
        let approver = relay.makeApprover()

        Task { [weak self] in
            do {
                let connected = try await SSHClientFactory.connect(
                    profile: snapshot, auth: auth, jumpHostAuth: jumpAuth,
                    hostKeyVerifier: verifier, hostKeyApprover: approver)
                let session: any SFTPProviding = try await SFTPSession(connected: connected)
                let home = (try? await session.realPath(".")) ?? "/"
                await MainActor.run {
                    self?.session = session
                    self?.state = .connected
                    self?.path = home
                    Self.markConnected(pid, in: container)
                }
                await self?.load(home)
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    func load(_ target: String) async {
        guard let session else { return }
        loading = true
        do {
            let list = try await session.list(path: target)
            let sorted = list.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            entries = sorted
            path = target
        } catch {
            state = .failed(error.localizedDescription)
        }
        loading = false
    }

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

    func refresh() { Task { await load(path) } }

    func delete(_ entry: RemoteEntry) {
        guard let session else { return }
        let full = joined(path, entry.name)
        Task { [weak self] in
            do {
                if entry.isDirectory { try await session.removeDirectory(full) }
                else { try await session.removeFile(full) }
                await self?.load(self?.path ?? "/")
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    func close() {
        let s = session
        Task { await s?.close() }
        session = nil
    }

    /// 失败后重连（连接中页「重试」）；只有处于失败态时才生效。
    func restart() {
        guard case .failed = state,
              let profile = lastProfile, let container = lastContainer, let relay = lastRelay else { return }
        let old = session
        Task { await old?.close() }
        session = nil
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
    func chmod(_ entry: RemoteEntry, mode: UInt32) {
        guard let session else { return }
        let full = joined(path, entry.name)
        Task { [weak self] in
            do {
                try await session.setPermissions(path: full, mode: mode & 0o777)
                await self?.load(self?.path ?? "/")
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// 重命名（同目录内移动）。
    func rename(_ entry: RemoteEntry, to newName: String) {
        guard let session else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        let from = joined(path, entry.name)
        let to = joined(path, trimmed)
        Task { [weak self] in
            do {
                try await session.rename(from, to: to)
                await self?.load(self?.path ?? "/")
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// 下载到临时文件，返回本地 URL（供系统分享面板使用）。
    func download(_ entry: RemoteEntry) async -> URL? {
        guard let session else { return nil }
        let full = joined(path, entry.name)
        do {
            let data = try await session.download(remotePath: full)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
            try? FileManager.default.removeItem(at: url)
            try data.write(to: url)
            return url
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    /// 从本地文件上传到当前目录。
    func upload(from url: URL) {
        guard let session else { return }
        let dest = joined(path, url.lastPathComponent)
        Task { [weak self] in
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                try await session.upload(data: data, toRemotePath: dest)
                await self?.load(self?.path ?? "/")
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func joined(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}
