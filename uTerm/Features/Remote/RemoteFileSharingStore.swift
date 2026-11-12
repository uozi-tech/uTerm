import Foundation
import Observation

/// 本机（主控端）共享给各台被控 Mac 的文件夹。
///
/// 被控 Mac 终端里的程序（Agent、`utermctl`）可以经远控链路反过来读写这些文件夹，别的地方一概碰不到；
/// 也不能在本机跑命令。默认什么都不共享，要用户自己一台一台、一个文件夹一个文件夹地加。
/// 只存在本机，不同步：共享的是这台 Mac 上的路径。
@MainActor
@Observable
final class RemoteFileSharingStore {
    /// Mac 的 id（`RemoteMacDirectory.Mac.id`）→ 共享给它的文件夹。
    private(set) var shares: [String: [RemoteFileRoot]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = RemoteLocalState.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: DefaultsKey.remoteSharedFolders),
           let stored = try? JSONDecoder().decode([String: [RemoteFileRoot]].self, from: data) {
            shares = stored
        }
    }

    func roots(for macID: String) -> [RemoteFileRoot] {
        shares[macID] ?? []
    }

    /// 加一个共享文件夹。已经加过的只改读写权限。
    func add(_ path: String, writable: Bool, for macID: String) {
        let path = (path as NSString).standardizingPath
        var roots = shares[macID] ?? []
        if let index = roots.firstIndex(where: { $0.path == path }) {
            roots[index].writable = writable
        } else {
            roots.append(RemoteFileRoot(path: path, writable: writable))
        }
        shares[macID] = roots
        save()
    }

    func setWritable(_ writable: Bool, path: String, for macID: String) {
        guard var roots = shares[macID], let index = roots.firstIndex(where: { $0.path == path }) else { return }
        roots[index].writable = writable
        shares[macID] = roots
        save()
    }

    func remove(_ path: String, for macID: String) {
        guard var roots = shares[macID] else { return }
        roots.removeAll { $0.path == path }
        shares[macID] = roots.isEmpty ? nil : roots
        save()
    }

    /// 忘记这台 Mac 时一并收回。
    func removeAll(for macID: String) {
        guard shares.removeValue(forKey: macID) != nil else { return }
        save()
    }

    /// 这台 Mac 此刻能访问的范围；什么都没共享回 nil。
    func scope(for macID: String) -> RemoteFileScope? {
        let roots = roots(for: macID)
        return roots.isEmpty ? nil : RemoteFileScope(roots: roots)
    }

    private func save() {
        if shares.isEmpty {
            defaults.removeObject(forKey: DefaultsKey.remoteSharedFolders)
        } else if let data = try? JSONEncoder().encode(shares) {
            defaults.set(data, forKey: DefaultsKey.remoteSharedFolders)
        }
    }

    /// 给某台 Mac 的连接用的门禁与执行：范围每条请求现查，执行交给不带沙盒的辅助程序（范围检查也在那边做）。
    func access(for macID: String) -> RemoteFileSharingAccess {
        RemoteFileSharingAccess(scope: { [weak self] in self?.scope(for: macID) }, perform: { payload, scope in
            do {
                return try await LocalShellService.shared.client.fileRequest(payload, scope: scope)
            } catch {
                return RemoteFileCodec.packReply(
                    .failure(RemoteFileCodec.requestID(of: payload) ?? UUID(),
                             RemoteFileError(.unreachable, "那台 Mac 上的辅助程序没有响应：\(error.localizedDescription)")),
                    compress: false)
            }
        })
    }

    /// 测试用：范围检查和执行都在本进程里做，不碰辅助程序。
    func inProcessAccess(for macID: String) -> RemoteFileSharingAccess {
        RemoteFileSharingAccess(scope: { [weak self] in self?.scope(for: macID) }, perform: { payload, scope in
            RemoteFileService.handle(payload, scope: scope)
        })
    }
}
