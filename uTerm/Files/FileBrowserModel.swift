import SwiftUI
import SwiftData

/// 文件浏览面板的状态机。导航/刷新/上传/下载经一个 `SFTPProviding`。
/// 生产用 `connect(...)` 建一个真实 `SFTPSession`；测试用 `init(testProvider:startPath:)`。
@MainActor
@Observable
final class FileBrowserModel {
    enum State: Equatable {
        case idle, connecting, browsing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var currentPath: String = "/"
    private(set) var entries: [RemoteEntry] = []

    /// 主机密钥审批的 UI 桥接（驱动 `FileBrowserView` 的 sheet）。
    let hostKeyRelay = HostKeyChallengeRelay()

    private var provider: (any SFTPProviding)?
    private(set) var transientError: String?

    init() {}

    init(testProvider: any SFTPProviding, startPath: String) {
        self.provider = testProvider
        self.currentPath = startPath
        self.state = .browsing
    }

    func connect(profile: ServerProfile, modelContainer: ModelContainer) async {
        // 视图层 `.task(id:)` 会在视图重建时重新触发 connect；已连接/连接中则视为
        // no-op，不撕掉活动 SFTP 会话。仅 .idle（首次）/ .failed（重试）才继续。
        guard state == .idle || { if case .failed = state { return true } else { return false } }() else { return }
        state = .connecting
        let keychain = KeychainStore()
        do {
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
            let session = try await SFTPSession(connected: connected)
            provider = session
            currentPath = (try? await session.realPath(".")) ?? "/"
            await refresh()
        } catch {
            state = .failed("\(error)")
        }
    }

    func refresh() async {
        guard let provider else { return }
        do {
            entries = try await provider.list(path: currentPath)
            state = .browsing
            transientError = nil
        } catch {
            state = .failed("\(error)")
        }
    }

    func navigate(into entry: RemoteEntry) async {
        guard entry.isDirectory else { return }
        currentPath = Self.join(currentPath, entry.name)
        await refresh()
    }

    func navigateUp() async {
        guard currentPath != "/" else { return }
        currentPath = Self.parent(of: currentPath)
        await refresh()
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

    func dispose() {
        hostKeyRelay.resolve(false)
        let p = provider
        provider = nil
        Task { await p?.close() }
    }

    /// 清除一次性错误（绑定到错误 alert 的关闭）。
    func clearTransientError() {
        transientError = nil
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
}
