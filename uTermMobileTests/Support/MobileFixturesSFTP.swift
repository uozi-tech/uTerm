import Foundation
import SwiftData
@testable import uTermMobile

/// 假 SFTP：一棵**可增删改**的内存目录树 + 一个实现产品协议 `SFTPProviding` 的
/// 假会话，可以直接注入 `MobileSFTPController`。
///
/// ## 注入口（2026-09-08 起）
///
/// `MobileSFTPController` 现在把会话声明成 `any SFTPProviding`（与桌面
/// `FileBrowserModel` 同一个协议），并有一条与桌面同形的测试注入口：
///
/// ```swift
/// MobileSFTPController(testProvider: provider, startPath: "/")
/// ```
///
/// 于是**产品自己的每条路径都跑得起来**：`load` / `open` / `goUp` / `refresh` /
/// `delete` / `rename` / `chmod` / `download` / `upload` 不再 `guard let session`
/// 空转。上一版夹具是直接写 `state` / `path` / `entries` 三个字段绕过 `start()`，
/// 那条路已经不需要了（`MobileFakeSFTP.controller(provider:)` 改走真实 `load`）。
///
/// 生产路径不变：`start(profile:container:relay:)` 建的仍是真实 Citadel
/// `SFTPSession`，只是存进了协议类型的字段。
///
/// ## 这份假会话覆盖什么
///
/// `SFTPProviding` 的全部要求，都落在内存目录树上并真的改变后续 `list` 的结果：
/// 列目录 / realPath / stat / mkdir / 新建空文件 / 删文件 / 删目录 / 改名 / chmod /
/// 读（含有界读与流式落盘）/ 写（含流式上传）/ exec / 存活探测 / close。
///
/// - **时延**：`latency` 非 0 时**每一次**往返都真的 `Task.sleep`
///   （50ms ≈ 同城内网一次 SFTP 往返）。
/// - **失败注入**：`inject(_:at:message:)` 让指定操作（可指定路径，也可全路径）
///   抛错，用来量「失败后列表/状态怎么走」。
/// - **计数**：`callCount(_:)` 数每种操作发生了几次，探针拿它当证人
///   （例如「删一次只重列一次目录」）。
///
/// ## 与桌面 `uTermTests/Support/MockSFTP` 的分工
///
/// 两边实现的是**同一个协议** `SFTPProviding`，语义对齐（同样的 EXCL 新建文件、
/// 同样的 `& 0o777`、同样的进度回调时机）。差别只在用途，没有第三份实现：
///
/// | | `MockSFTP`（macOS） | `MobileFakeSFTPProvider`（iOS） |
/// |---|---|---|
/// | 目录树 | 静态 `[String: [RemoteEntry]]`，改名/删除只记账不改树 | 真的改树，后续 `list` 看得到 |
/// | 侧重 | 断言用的录音机（`renames` / `removedFiles` / `uploads` …） | 规模化的假服务器（500 / 20000 条、时延、失败注入） |
/// | 规模 | 手写几条 | `MobileFakeSFTPTree.entries(count:)` 生成 |
///
/// 两个测试 target（`uTermTests` / `uTermMobileTests`）各自是一个
/// `PBXFileSystemSynchronizedRootGroup`，一个文件进不了两个 target，所以合成
/// 单一文件需要动 pbxproj 的同步组结构 —— 本轮没做（见任务报告）。

// MARK: - 错误

/// 假会话抛出的错误。语义对齐真实 SFTP 状态码里我们真正会碰到的那几种。
enum MobileFakeSFTPError: Error, Equatable, CustomStringConvertible {
    case noSuchFile(String)
    case notADirectory(String)
    case fileExists(String)
    case directoryNotEmpty(String)
    /// 由 `inject(_:at:message:)` 注入。
    case injected(operation: String, path: String, message: String)

    var description: String {
        switch self {
        case .noSuchFile(let p):        return "no such file: \(p)"
        case .notADirectory(let p):     return "not a directory: \(p)"
        case .fileExists(let p):        return "file exists: \(p)"
        case .directoryNotEmpty(let p): return "directory not empty: \(p)"
        case .injected(let op, let p, let m): return "\(op) failed on \(p): \(m)"
        }
    }

    var localizedDescription: String { description }
}

// MARK: - 目录树

/// 一棵内存目录树 + 文件内容表。值类型；`MobileFakeSFTPProvider` 持有并原地改。
///
/// **路径约定**：绝对路径、`/` 开头、不带尾斜杠，根就是 `"/"`（`normalize` 统一）。
///
/// **大小与内容是两件事**（重要）：生成器刻意造出 0B~40GB 的条目好把 UI 的单位
/// 分支走全，但假会话**不会**为一个 40GB 的条目真的造 40GB 字节。没写过内容的
/// 文件读出来的是确定性合成载荷，长度钳在 `syntheticContentCap`；而 `stat` /
/// 列表返回的仍是条目**声明**的大小。写过（`write` / `upload`）之后两者一致。
struct MobileFakeSFTPTree: Sendable {
    /// 目录路径 → 条目表。
    private(set) var directories: [String: [RemoteEntry]]
    /// 文件全路径 → 内容。只存被写过 / 被显式塞过的文件。
    private(set) var blobs: [String: Data] = [:]
    /// `realPath(".")` 返回的家目录。
    var home: String
    /// 未写过内容的文件，读出来最多合成这么多字节（默认 64 KiB）。
    var syntheticContentCap = 64 * 1024

    init(directories: [String: [RemoteEntry]], home: String = "/") {
        self.directories = directories
        self.home = home
    }

    /// 列一个目录。不存在的目录返回空数组（真实 SFTP 会抛错，但探针要的是
    /// 「滚得动」，不是错误路径——错误路径走 `inject(.list, …)`）。
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

    static func join(_ base: String, _ name: String) -> String {
        normalize(base) == "/" ? "/\(name)" : "\(normalize(base))/\(name)"
    }

    static func split(_ path: String) -> (parent: String, name: String) {
        let p = normalize(path)
        guard p != "/" else { return ("/", "") }
        let parent = (p as NSString).deletingLastPathComponent
        return (parent.isEmpty ? "/" : parent, (p as NSString).lastPathComponent)
    }

    // MARK: 查询

    /// 某个全路径对应的条目（根目录自身没有条目，返回 nil）。
    func entry(at path: String) -> RemoteEntry? {
        let (parent, name) = Self.split(path)
        guard !name.isEmpty else { return nil }
        return directories[Self.normalize(parent)]?.first { $0.name == name }
    }

    func isDirectory(_ path: String) -> Bool {
        directories[Self.normalize(path)] != nil
    }

    /// 读一个文件的字节。写过的返回真内容；没写过的合成确定性载荷（长度钳在
    /// `syntheticContentCap`），这样 20000 条的极端档不用真的占内存。
    func contents(at path: String) throws -> Data {
        let p = Self.normalize(path)
        if let blob = blobs[p] { return blob }
        guard let entry = entry(at: p), !entry.isDirectory else {
            throw MobileFakeSFTPError.noSuchFile(p)
        }
        let want = Int(min(UInt64(syntheticContentCap), entry.size ?? 0))
        guard want > 0 else { return Data() }
        var data = Data(capacity: want)
        var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: p.hashValue))
        while data.count < want {
            withUnsafeBytes(of: rng.next().littleEndian) { data.append(contentsOf: $0) }
        }
        return data.prefix(want)
    }

    // MARK: 变更

    /// 落一个条目进某个目录，保持产品的排序（目录在前、按名不区分大小写升序）。
    private mutating func insert(_ entry: RemoteEntry, into dir: String) {
        let d = Self.normalize(dir)
        var list = directories[d] ?? []
        list.removeAll { $0.name == entry.name }
        list.append(entry)
        directories[d] = Self.sorted(list)
    }

    static func sorted(_ list: [RemoteEntry]) -> [RemoteEntry] {
        list.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// mkdir。父目录必须存在，路径不能已被占用。
    mutating func makeDirectory(_ path: String) throws {
        let p = Self.normalize(path)
        let (parent, name) = Self.split(p)
        guard directories[Self.normalize(parent)] != nil else {
            throw MobileFakeSFTPError.noSuchFile(parent)
        }
        guard entry(at: p) == nil else { throw MobileFakeSFTPError.fileExists(p) }
        insert(RemoteEntry(name: name, posixPermissions: 0o040000 | 0o755,
                           size: 4096, modifiedAt: Date(),
                           uid: 1000, gid: 1000,
                           ownerName: "ubuntu", groupName: "ubuntu"),
               into: parent)
        directories[p] = []
    }

    /// 新建空文件（EXCL：已存在就抛，绝不截断）。
    mutating func createFile(_ path: String) throws {
        let p = Self.normalize(path)
        let (parent, name) = Self.split(p)
        guard directories[Self.normalize(parent)] != nil else {
            throw MobileFakeSFTPError.noSuchFile(parent)
        }
        guard entry(at: p) == nil else { throw MobileFakeSFTPError.fileExists(p) }
        insert(RemoteEntry(name: name, posixPermissions: 0o100000 | 0o644,
                           size: 0, modifiedAt: Date(),
                           uid: 1000, gid: 1000,
                           ownerName: "ubuntu", groupName: "ubuntu"),
               into: parent)
        blobs[p] = Data()
    }

    /// 写内容（覆盖；不存在就建）。条目声明的大小同步跟上。
    mutating func write(_ path: String, data: Data) throws {
        let p = Self.normalize(path)
        let (parent, name) = Self.split(p)
        guard !name.isEmpty, directories[Self.normalize(parent)] != nil else {
            throw MobileFakeSFTPError.noSuchFile(parent)
        }
        if isDirectory(p) { throw MobileFakeSFTPError.fileExists(p) }
        let old = entry(at: p)
        insert(RemoteEntry(name: name,
                           posixPermissions: old?.permissions ?? (0o100000 | 0o644),
                           size: UInt64(data.count), modifiedAt: Date(),
                           uid: old?.uid ?? 1000, gid: old?.gid ?? 1000,
                           ownerName: old?.ownerName ?? "ubuntu",
                           groupName: old?.groupName ?? "ubuntu"),
               into: parent)
        blobs[p] = data
    }

    /// 删文件。目标必须存在且不是目录。
    mutating func removeFile(_ path: String) throws {
        let p = Self.normalize(path)
        guard let e = entry(at: p) else { throw MobileFakeSFTPError.noSuchFile(p) }
        guard !e.isDirectory else { throw MobileFakeSFTPError.notADirectory(p) }
        let (parent, name) = Self.split(p)
        directories[Self.normalize(parent)]?.removeAll { $0.name == name }
        blobs[p] = nil
    }

    /// 删目录（非递归，非空即抛 —— 与真实 rmdir 一致）。
    mutating func removeDirectory(_ path: String) throws {
        let p = Self.normalize(path)
        guard let e = entry(at: p), e.isDirectory else {
            throw MobileFakeSFTPError.noSuchFile(p)
        }
        if let children = directories[p], !children.isEmpty {
            throw MobileFakeSFTPError.directoryNotEmpty(p)
        }
        let (parent, name) = Self.split(p)
        directories[Self.normalize(parent)]?.removeAll { $0.name == name }
        directories[p] = nil
    }

    /// 改名 / 同层移动。目录改名会把整棵子树的路径键一起搬走。
    mutating func rename(_ path: String, to newPath: String) throws {
        let from = Self.normalize(path)
        let to = Self.normalize(newPath)
        guard let e = entry(at: from) else { throw MobileFakeSFTPError.noSuchFile(from) }
        guard entry(at: to) == nil else { throw MobileFakeSFTPError.fileExists(to) }
        let (fromParent, fromName) = Self.split(from)
        let (toParent, toName) = Self.split(to)
        guard directories[Self.normalize(toParent)] != nil else {
            throw MobileFakeSFTPError.noSuchFile(toParent)
        }
        directories[Self.normalize(fromParent)]?.removeAll { $0.name == fromName }
        insert(RemoteEntry(name: toName, posixPermissions: e.permissions,
                           size: e.size, modifiedAt: e.modifiedAt,
                           uid: e.uid, gid: e.gid,
                           ownerName: e.ownerName, groupName: e.groupName),
               into: toParent)
        if e.isDirectory {
            for key in directories.keys where key == from || key.hasPrefix(from + "/") {
                let moved = to + key.dropFirst(from.count)
                directories[moved] = directories[key]
                directories[key] = nil
            }
            for key in blobs.keys where key.hasPrefix(from + "/") {
                let moved = to + key.dropFirst(from.count)
                blobs[moved] = blobs[key]
                blobs[key] = nil
            }
        } else if let blob = blobs[from] {
            blobs[from] = nil
            blobs[to] = blob
        }
    }

    /// chmod（只改低 9 位，保留文件类型位 —— 与 `SFTPSession.setPermissions` 一致）。
    mutating func setPermissions(_ path: String, mode: UInt32) throws {
        let p = Self.normalize(path)
        guard let e = entry(at: p) else { throw MobileFakeSFTPError.noSuchFile(p) }
        let (parent, _) = Self.split(p)
        let typeBits = (e.permissions ?? 0) & 0o170000
        insert(RemoteEntry(name: e.name, posixPermissions: typeBits | (mode & 0o777),
                           size: e.size, modifiedAt: e.modifiedAt,
                           uid: e.uid, gid: e.gid,
                           ownerName: e.ownerName, groupName: e.groupName),
               into: parent)
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
                } else {
                    // 叶子目录也要在树里有一条（空目录），否则「进得去但列不出」。
                    dirs[normalize(path == "/" ? "/\(name)" : "\(path)/\(name)")] = []
                }
            } else if i % 17 == 3 {
                list.append(makeEntry(name: fileName(i), kind: .symlink, index: i, rng: &rng))
            } else {
                list.append(makeEntry(name: fileName(i), kind: .file, index: i, rng: &rng))
            }
        }
        // 与产品一致的排序：目录在前，其余按名字不区分大小写升序
        // （`MobileSFTPController.load` 里那一段）。
        dirs[normalize(path)] = sorted(list)
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

// MARK: - 假会话

/// 内存假 SFTP 会话：实现产品协议 `SFTPProviding`，可以直接注入
/// `MobileSFTPController(testProvider:startPath:)`，不发起任何真实连接。
///
/// 是 `actor` 因为 `SFTPProviding: Actor`（协议本身就要求）。所以读计数器 /
/// 读树都要 `await`。
actor MobileFakeSFTPProvider: SFTPProviding {

    /// 可注入失败、可计数的操作面。名字对齐 `SFTPProviding` 的方法。
    enum Operation: String, Sendable, CaseIterable {
        case list, realPath, stat, exec
        case download, upload, write
        case rename, removeFile, removeDirectory, createDirectory, createFile
        case setPermissions, close
    }

    /// 当前目录树（探针可以直接查证「删完真的没了」）。
    private(set) var tree: MobileFakeSFTPTree
    /// 每次往返的模拟网络时延。`.zero` = 立即返回（默认，量挂载成本用）；
    /// `.milliseconds(50)` ≈ 同城内网一次往返。
    let latency: Duration

    private var counts: [Operation: Int] = [:]
    private var injected: [Operation: (paths: Set<String>?, message: String)] = [:]
    private(set) var didClose = false
    /// `exec` 的可控返回值。
    private var execOutput = ""
    private(set) var execCommands: [String] = []
    /// `verifyConnectionAlive` 的返回值（默认活）。
    private var alive = true

    init(tree: MobileFakeSFTPTree, latency: Duration = .zero) {
        self.tree = tree
        self.latency = latency
    }

    init(entries count: Int, subdirectories: Int = 0, childCount: Int = 0,
         depth: Int = 1, latency: Duration = .zero,
         seedValue: UInt64 = 0x5F7F_0001) {
        self.init(tree: .entries(count: count, subdirectories: subdirectories,
                                 childCount: childCount, depth: depth,
                                 seedValue: seedValue),
                  latency: latency)
    }

    // MARK: 探针接口（计数 / 注入 / 直查）

    func callCount(_ op: Operation) -> Int { counts[op] ?? 0 }
    /// 老名字，保留给既有用例。
    var listCallCount: Int { callCount(.list) }
    func resetCounts() { counts = [:] }

    /// 让某个操作抛错。`path == nil` = 所有路径都抛。
    func inject(_ op: Operation, at path: String? = nil,
                message: String = "假会话注入的失败") {
        var paths = injected[op]?.paths
        if let path {
            var set = paths ?? []
            set.insert(MobileFakeSFTPTree.normalize(path))
            paths = set
        } else {
            paths = nil
        }
        injected[op] = (paths, message)
    }
    func clearInjections() { injected = [:] }

    func setExecOutput(_ s: String) { execOutput = s }
    func setAlive(_ v: Bool) { alive = v }

    /// 直接塞一个文件的内容（不计入 `write` 计数），用来给下载探针准备语料。
    func seedFile(_ path: String, data: Data) throws {
        try tree.write(path, data: data)
    }

    func listSnapshot(_ path: String) -> [RemoteEntry] { tree.list(path) }
    func entrySnapshot(at path: String) -> RemoteEntry? { tree.entry(at: path) }

    // MARK: 内部

    /// 一次往返：计数 → 时延 → 失败注入。
    private func hop(_ op: Operation, _ path: String) async throws {
        counts[op, default: 0] += 1
        if latency != .zero { try? await Task.sleep(for: latency) }
        guard let rule = injected[op] else { return }
        let p = MobileFakeSFTPTree.normalize(path)
        if rule.paths == nil || rule.paths?.contains(p) == true {
            throw MobileFakeSFTPError.injected(operation: op.rawValue, path: p,
                                               message: rule.message)
        }
    }

    // MARK: SFTPProviding —— 读

    func list(path: String) async throws -> [RemoteEntry] {
        try await hop(.list, path)
        return tree.list(path)
    }

    func realPath(_ path: String) async throws -> String {
        try await hop(.realPath, path)
        return path == "." ? tree.home : MobileFakeSFTPTree.normalize(path)
    }

    func stat(_ path: String) async throws -> RemoteStat {
        try await hop(.stat, path)
        guard let entry = tree.entry(at: path) else {
            throw MobileFakeSFTPError.noSuchFile(path)
        }
        return RemoteStat(size: Int64(clamping: entry.size ?? 0),
                          mtime: entry.modifiedAt ?? Date())
    }

    func exec(_ command: String) async throws -> String {
        try await hop(.exec, "/")
        execCommands.append(command)
        return execOutput
    }

    func download(remotePath: String) async throws -> Data {
        try await download(remotePath: remotePath, onProgress: nil)
    }

    func download(remotePath: String,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        try await hop(.download, remotePath)
        let data = try tree.contents(at: remotePath)
        emitWholeTransfer(data.count, onProgress)
        return data
    }

    /// 流式落盘。与真实实现一致：先写同目录临时文件，成功才顶替目标；
    /// 失败 / 取消不留半截文件。
    func download(remotePath: String, toLocalURL localURL: URL,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try await hop(.download, remotePath)
        let data = try tree.contents(at: remotePath)
        let total = Int64(data.count)
        let temporaryURL = localURL.deletingLastPathComponent().appendingPathComponent(
            ".\(localURL.lastPathComponent).fake-\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        var emitter = TransferProgressEmitter(totalBytes: total)
        do {
            var offset = 0
            let chunk = 32 * 1024
            if emitter.shouldEmit(bytesDone: 0) {
                onProgress?(TransferProgress(bytesDone: 0, bytesTotal: total))
            }
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + chunk, data.count)
                try handle.write(contentsOf: data[offset..<end])
                offset = end
                if emitter.shouldEmit(bytesDone: Int64(offset)) {
                    onProgress?(TransferProgress(bytesDone: Int64(offset), bytesTotal: total))
                }
            }
            try handle.close()
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: localURL)
            }
            onProgress?(TransferProgress(bytesDone: total, bytesTotal: total))
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    // MARK: SFTPProviding —— 写

    func upload(data: Data, toRemotePath: String) async throws {
        try await upload(data: data, toRemotePath: toRemotePath, onProgress: nil)
    }

    func upload(data: Data, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try await hop(.upload, toRemotePath)
        try tree.write(toRemotePath, data: data)
        emitWholeTransfer(data.count, onProgress)
    }

    /// 流式上传：按 32KB 读本地文件，不构造整文件级的第二份 `Data` 副本之外的中间缓冲。
    func upload(localURL: URL, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        try await hop(.upload, toRemotePath)
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let total = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var accumulated = Data()
        var emitter = TransferProgressEmitter(totalBytes: total)
        if emitter.shouldEmit(bytesDone: 0) {
            onProgress?(TransferProgress(bytesDone: 0, bytesTotal: total))
        }
        while let chunk = try handle.read(upToCount: 32 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            accumulated.append(chunk)
            if emitter.shouldEmit(bytesDone: Int64(accumulated.count)) {
                onProgress?(TransferProgress(bytesDone: Int64(accumulated.count),
                                             bytesTotal: total))
            }
        }
        try tree.write(toRemotePath, data: accumulated)
        onProgress?(TransferProgress(bytesDone: Int64(accumulated.count), bytesTotal: total))
    }

    func write(_ path: String, data: Data) async throws {
        try await hop(.write, path)
        try tree.write(path, data: data)
    }

    // MARK: SFTPProviding —— 目录 / 改名 / 删除 / 权限

    func rename(_ path: String, to newPath: String) async throws {
        try await hop(.rename, path)
        try tree.rename(path, to: newPath)
    }

    func removeFile(_ path: String) async throws {
        try await hop(.removeFile, path)
        try tree.removeFile(path)
    }

    func removeDirectory(_ path: String) async throws {
        try await hop(.removeDirectory, path)
        try tree.removeDirectory(path)
    }

    func createDirectory(_ path: String) async throws {
        try await hop(.createDirectory, path)
        try tree.makeDirectory(path)
    }

    func createFile(_ path: String) async throws {
        try await hop(.createFile, path)
        try tree.createFile(path)
    }

    func setPermissions(path: String, mode: UInt32) async throws {
        try await hop(.setPermissions, path)
        try tree.setPermissions(path, mode: mode)
    }

    // MARK: SFTPProviding —— 生命周期

    func verifyConnectionAlive() async -> Bool { alive }

    func close() async {
        counts[.close, default: 0] += 1
        didClose = true
    }

    // MARK: 进度

    /// 非流式接口的进度：首尾两拍（与真实实现「首块必发、完成必达」一致）。
    private nonisolated func emitWholeTransfer(
        _ count: Int, _ onProgress: (@Sendable (TransferProgress) -> Void)?
    ) {
        guard let onProgress else { return }
        let total = Int64(count)
        onProgress(TransferProgress(bytesDone: 0, bytesTotal: total))
        onProgress(TransferProgress(bytesDone: total, bytesTotal: total))
    }
}

// MARK: - 挂载器

/// 把假会话挂进 `MobileSFTPController` / `MobileSFTPSession`，
/// 让 `SFTPScreen` 无需任何真实连接就能渲染浏览态。
///
/// 与上一版的区别：不再手写 `state` / `path` / `entries`，一律走产品自己的
/// `MobileSFTPController(testProvider:startPath:)` + `load(_:)`。
@MainActor
enum MobileFakeSFTP {

    /// 造一个已经「连上并列好目录」的控制器（走产品的 `load`，含它自己的排序）。
    static func controller(provider: MobileFakeSFTPProvider,
                           path: String? = nil) async -> MobileSFTPController {
        // 不能写成 `path ?? (try? await ...)`：`??` 的右侧是**非 async** 的
        // autoclosure，`await` 进不去。老老实实分两步。
        var resolved = path
        if resolved == nil { resolved = try? await provider.realPath(".") }
        let target = resolved ?? "/"
        let controller = MobileSFTPController(testProvider: provider, startPath: target)
        await controller.load(target)
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

    /// 换目录：走产品的 `load(_:)`（可 await，读数确定）。
    @discardableResult
    static func enter(_ controller: MobileSFTPController,
                      provider: MobileFakeSFTPProvider,
                      path: String) async -> [RemoteEntry] {
        await controller.load(path)
        return controller.entries
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

    /// 等一个「发射后不管」的控制器动作落地。
    ///
    /// `open` / `goUp` / `refresh` / `delete` / `rename` / `chmod` / `upload`
    /// 内部都是 `Task { … }`，调用点拿不到句柄。探针要量端到端就得等到条件成立；
    /// 这里轮询 `Task.yield()`（不 sleep，免得把等待本身算进读数）。
    /// 超时抛错而不是静默返回 —— 「没等到」必须判红。
    @discardableResult
    static func settle(timeoutSeconds: Double = 10,
                       _ what: String = "条件",
                       until condition: @MainActor () -> Bool) async throws -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        while !condition() {
            if CFAbsoluteTimeGetCurrent() - start > timeoutSeconds {
                throw MobileFakeSFTPError.injected(
                    operation: "settle", path: what,
                    message: "\(timeoutSeconds)s 内没等到「\(what)」成立")
            }
            await Task.yield()
        }
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
}

// MARK: - 断言小工具

extension RemoteEntry {
    /// 「常规文件」：既不是目录也不是符号链接。
    ///
    /// 改名 / chmod 的断言要落在常规文件上 —— symlink 的类型位是 `0o120000`，
    /// 拿它去比 `0o100000 | mode` 会假红，而假树里每 17 条就有一条 symlink。
    var isRegularFileForProbe: Bool { !isDirectory && !isSymlink }
}
