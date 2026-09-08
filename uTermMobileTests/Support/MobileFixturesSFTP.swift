import Foundation
import SwiftData
@testable import uTermMobile

/// 假 SFTP：一棵可配的内存目录树 + 一个把它挂进 `MobileSFTPController` 的挂载器。
///
/// ## 为什么是「挂载器」而不是「注入的 provider」
///
/// `MobileSFTPController` 直接持有一个具体的 `SFTPSession`（Citadel）：
///
/// ```swift
/// @ObservationIgnored private var session: SFTPSession?
/// ```
///
/// 既没有协议、也没有 init 注入点，`start(profile:container:relay:)` 一路走到真实
/// SSH 建连。产品代码本轮不动，所以夹具走的是**另一条合法路径**：控制器的
/// `state` / `path` / `entries` 三个字段都是 internal `var`，`@testable import`
/// 之后可以直接写。于是「挂载」= 绕过 `start()`，把假目录直接填进这三个字段。
///
/// 由此带来的**已知局限**（探针要清楚）：
/// - `controller.open(_:)` / `goUp()` / `refresh()` / `load(_:)` 内部都 `guard let session`，
///   session 恒 nil → **点目录行不会真的进目录**。要换目录得调
///   `MobileFakeSFTP.enter(_:path:)`，它走假 provider 再回填。
/// - `delete` / `rename` / `chmod` / `download` / `upload` 同理，全是 no-op。
///   要量这些交互的端到端成本，只能等产品侧把 session 抽成协议。
///
/// 时延：`latency` 非 0 时 `list` 会真的 `Task.sleep`，用来复现「网络回来之前
/// 列表是空的」那一段（50ms ≈ 同城内网一次 SFTP 列目录）。

// MARK: - 目录树

/// 一棵内存目录树。`path` → 该目录下的条目。
struct MobileFakeSFTPTree: Sendable {
    /// 目录路径（绝对，`/` 开头，不带尾斜杠，根就是 `"/"`）→ 条目表。
    private(set) var directories: [String: [RemoteEntry]]
    /// `realPath(".")` 返回的家目录。
    var home: String

    init(directories: [String: [RemoteEntry]], home: String = "/") {
        self.directories = directories
        self.home = home
    }

    /// 列一个目录。不存在的目录返回空数组（真实 SFTP 会抛错，但探针要的是
    /// 「滚得动」，不是错误路径——错误路径直接置 `controller.state = .failed`）。
    func list(_ path: String) -> [RemoteEntry] {
        directories[Self.normalize(path)] ?? []
    }

    var directoryCount: Int { directories.count }
    var totalEntries: Int { directories.values.reduce(0) { $0 + $1.count } }

    static func normalize(_ path: String) -> String {
        guard path != "/" else { return "/" }
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    // MARK: 生成

    /// 造一棵树：根目录 `count` 条，其中前 `subdirectories` 条是目录，
    /// 每个子目录里再放 `childCount` 条（子目录可进，深度 `depth` 层）。
    ///
    /// 条目形态刻意散开（都是排版 / 截断成本的来源）：
    /// - 文件名长短混合：`a.txt` 到 130 字符的长名，含中文与空格；
    /// - 类型混合：目录 / 普通文件 / 符号链接（`S_IFLNK`，`isDirectory` 恒 false）；
    /// - 大小从 0 到 ~40GB（`MFileIcon` 与副标题的格式化分支都要走到）；
    /// - 权限混合 0644 / 0755 / 0600 / 0777；
    /// - 修改时间散布在 3 年内（「今天 / 本月 / 去年」三种日期格式都出现）。
    static func entries(count: Int,
                        subdirectories: Int = 0,
                        childCount: Int = 0,
                        depth: Int = 1,
                        seedValue: UInt64 = 0x5F7F_0001) -> MobileFakeSFTPTree {
        var rng = SplitMix64(seed: seedValue)
        var dirs: [String: [RemoteEntry]] = [:]
        build(into: &dirs, at: "/", count: count,
              subdirectories: subdirectories, childCount: childCount,
              depth: depth, rng: &rng)
        return MobileFakeSFTPTree(directories: dirs, home: "/")
    }

    private static func build(into dirs: inout [String: [RemoteEntry]],
                              at path: String, count: Int,
                              subdirectories: Int, childCount: Int, depth: Int,
                              rng: inout SplitMix64) {
        var list: [RemoteEntry] = []
        list.reserveCapacity(count)
        let dirCount = max(0, min(subdirectories, count))
        for i in 0..<count {
            if i < dirCount {
                let name = directoryName(i)
                list.append(makeEntry(name: name, kind: .directory, index: i, rng: &rng))
                if depth > 1, childCount > 0 {
                    let child = path == "/" ? "/\(name)" : "\(path)/\(name)"
                    build(into: &dirs, at: child, count: childCount,
                          subdirectories: min(2, childCount), childCount: childCount / 2,
                          depth: depth - 1, rng: &rng)
                }
            } else if i % 17 == 3 {
                list.append(makeEntry(name: fileName(i), kind: .symlink, index: i, rng: &rng))
            } else {
                list.append(makeEntry(name: fileName(i), kind: .file, index: i, rng: &rng))
            }
        }
        // 与产品一致的排序：目录在前，其余按名字不区分大小写升序
        // （`MobileSFTPController.load` 里那一段）。
        dirs[normalize(path)] = list.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private enum Kind { case directory, file, symlink }

    private static func makeEntry(name: String, kind: Kind, index: Int,
                                  rng: inout SplitMix64) -> RemoteEntry {
        let typeBits: UInt32
        switch kind {
        case .directory: typeBits = 0o040000
        case .file:      typeBits = 0o100000
        case .symlink:   typeBits = 0o120000
        }
        let mode: UInt32 = [0o644, 0o755, 0o600, 0o777, 0o640][index % 5]
        let size: UInt64?
        switch kind {
        case .directory: size = 4096
        case .symlink:   size = UInt64(name.count)
        case .file:
            // 0B / 几百 B / 几 MB / 几十 GB 都要有，副标题的单位分支才走得全。
            switch index % 6 {
            case 0: size = 0
            case 1: size = UInt64.random(in: 1...900, using: &rng)
            case 2: size = UInt64.random(in: 1_024...900_000, using: &rng)
            case 3: size = UInt64.random(in: 1_000_000...900_000_000, using: &rng)
            case 4: size = UInt64.random(in: 1_000_000_000...40_000_000_000, using: &rng)
            default: size = UInt64.random(in: 2_000...80_000, using: &rng)
            }
        }
        let age = Double(index % 1_100) * 86_400 + Double(index % 3_600)
        return RemoteEntry(name: name,
                           posixPermissions: typeBits | mode,
                           size: size,
                           modifiedAt: Date(timeIntervalSinceNow: -age),
                           uid: [0, 1000, 1001, 33][index % 4],
                           gid: [0, 1000, 1001, 33][index % 4],
                           ownerName: ["root", "ubuntu", "deploy", "www-data"][index % 4],
                           groupName: ["root", "ubuntu", "deploy", "www-data"][index % 4])
    }

    private static func directoryName(_ i: Int) -> String {
        let base = ["etc", "var", "usr", "opt", "home", "srv", "日志归档", "backup-2026",
                    "node_modules", "很长的一个目录名字用来把行撑到需要截断为止 \(i)"]
        return i < base.count ? base[i] : "dir-\(String(format: "%04d", i))"
    }

    private static func fileName(_ i: Int) -> String {
        switch i % 8 {
        case 0: return "a\(i).txt"
        case 1: return "access-\(String(format: "%05d", i)).log"
        case 2: return "docker-compose.override.yml"
                    .replacingOccurrences(of: ".yml", with: "-\(i).yml")
        case 3: return "libexample-\(i).so.1.2.3"
        case 4: return "备份 \(i) —— 这是一个刻意很长的中文文件名，用来逼出单行截断与省略号，"
                    + "顺便验证宽字符的排版成本 (\(i)).tar.gz"
        case 5: return "id_ed25519_\(i).pub"
        case 6: return ".env.production.\(i)"
        default: return "report_\(i)_final_FINAL_v\(i % 9).pdf"
        }
    }
}

// MARK: - 假 provider

/// 假 SFTP provider 的协议形状 —— 只覆盖 `MobileSFTPController` 真正用到的两个
/// 读操作（`realPath(".")` 定家目录、`list(path:)` 全量列目录）。
protocol MobileFakeSFTPProviding: Sendable {
    func realPath(_ path: String) async throws -> String
    func list(path: String) async throws -> [RemoteEntry]
}

/// 内存实现。`latency` 非 0 时每次 `list` 都真的 sleep 一次。
final class MobileFakeSFTPProvider: MobileFakeSFTPProviding, @unchecked Sendable {
    let tree: MobileFakeSFTPTree
    /// 每次 `list` 的模拟网络时延。`.zero` = 立即返回（默认，量挂载成本用）；
    /// `.milliseconds(50)` ≈ 同城内网一次列目录（量「空列表 → 有内容」那一跳用）。
    let latency: Duration

    /// 已发生的 `list` 次数（自证测试与探针都要它当证人）。
    private(set) var listCallCount = 0

    init(tree: MobileFakeSFTPTree, latency: Duration = .zero) {
        self.tree = tree
        self.latency = latency
    }

    convenience init(entries count: Int, subdirectories: Int = 0, childCount: Int = 0,
                     depth: Int = 1, latency: Duration = .zero,
                     seedValue: UInt64 = 0x5F7F_0001) {
        self.init(tree: .entries(count: count, subdirectories: subdirectories,
                                 childCount: childCount, depth: depth, seedValue: seedValue),
                  latency: latency)
    }

    func realPath(_ path: String) async throws -> String { tree.home }

    func list(path: String) async throws -> [RemoteEntry] {
        listCallCount += 1
        if latency != .zero { try? await Task.sleep(for: latency) }
        return tree.list(path)
    }
}

// MARK: - 挂载器

/// 把假 provider 挂进 `MobileSFTPController` / `MobileSFTPSession`，
/// 让 `SFTPScreen` 无需任何真实连接就能渲染浏览态。
@MainActor
enum MobileFakeSFTP {

    /// 造一个已经「连上并列好目录」的控制器。
    ///
    /// 不走 `controller.start(...)`（那会真的建 SSH 连接），直接把三个字段填好：
    /// `state = .connected` / `path` / `entries`。
    static func controller(provider: MobileFakeSFTPProvider,
                           path: String? = nil) async -> MobileSFTPController {
        let controller = MobileSFTPController()
        // 不能写成 `path ?? (try? await ...)`：`??` 的右侧是**非 async** 的
        // autoclosure，`await` 进不去（"async call in a function that does not
        // support concurrency"）。老老实实分两步。
        var resolved = path
        if resolved == nil { resolved = try? await provider.realPath(".") }
        let target = resolved ?? "/"
        controller.state = .connected
        controller.path = target
        controller.entries = (try? await provider.list(path: target)) ?? []
        return controller
    }

    /// 造一个可以直接塞进 `SFTPScreen` 环境的会话。
    ///
    /// `activeTarget` 预设为 `host` 的 `PersistentIdentifier`，这一步**是必须的**：
    /// `SFTPScreen.consumeSFTPTarget` 只在 `activeTarget != store.sftpTarget` 时才
    /// 调 `controller.start(...)`；预设成相等，屏幕挂载时就整条跳过真实建连。
    static func session(host: ServerProfile,
                        provider: MobileFakeSFTPProvider,
                        path: String? = nil) async -> MobileSFTPSession {
        let session = MobileSFTPSession()
        session.controller = await controller(provider: provider, path: path)
        session.activeTarget = host.persistentModelID
        return session
    }

    /// 换目录：走假 provider 列一次再回填控制器。
    ///
    /// 探针要「点进子目录」时用这个，**不要**用 `controller.open(_:)` ——
    /// 后者 `guard let session` 直接返回（见文件头「已知局限」）。
    @discardableResult
    static func enter(_ controller: MobileSFTPController,
                      provider: MobileFakeSFTPProvider,
                      path: String) async -> [RemoteEntry] {
        controller.loading = true
        let list = (try? await provider.list(path: path)) ?? []
        controller.entries = list
        controller.path = MobileFakeSFTPTree.normalize(path)
        controller.loading = false
        return list
    }

    /// 上一级。根目录下是 no-op（与产品 `goUp()` 一致）。
    @discardableResult
    static func goUp(_ controller: MobileSFTPController,
                     provider: MobileFakeSFTPProvider) async -> [RemoteEntry] {
        guard controller.path != "/" else { return controller.entries }
        let parent = (controller.path as NSString).deletingLastPathComponent
        return await enter(controller, provider: provider,
                           path: parent.isEmpty ? "/" : parent)
    }
}
