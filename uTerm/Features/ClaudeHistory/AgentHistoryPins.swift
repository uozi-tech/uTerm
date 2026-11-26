import CoreGraphics
import Foundation
import Observation

/// 置顶的一个会话：工具 + 会话 ID。不带标题、路径、项目名：置顶只记「是哪一个」，别的都从列表里现读。
///
/// 会话 ID 是记录文件（或会话目录）的名字，由编码工具自己定，同一台主机上同一种工具里不重复；换了项目目录也不变。
nonisolated struct AgentHistoryPinKey: Hashable, Sendable {
    let tool: AgentHistoryTool
    let sessionID: String

    init(tool: AgentHistoryTool, sessionID: String) {
        self.tool = tool
        self.sessionID = sessionID
    }

    init(_ file: AgentHistorySessionFile) {
        self.init(tool: file.tool, sessionID: file.sessionID)
    }

    /// 每个键对上的第一份记录（`files` 新的在前，同一个键有好几份时取最新那份）。
    static func firstFiles(in files: [AgentHistorySessionFile]) -> [AgentHistoryPinKey: AgentHistorySessionFile] {
        var first: [AgentHistoryPinKey: AgentHistorySessionFile] = [:]
        for file in files where first[AgentHistoryPinKey(file)] == nil { first[AgentHistoryPinKey(file)] = file }
        return first
    }

    /// 存储里的写法：`工具原始值:会话 ID`（如 `claude:0b7e…`）。
    var stored: String { "\(tool.rawValue):\(sessionID)" }

    /// 认不出的工具（以后删掉的）或者没有会话 ID 的为 nil。
    init?(stored: String) {
        guard let colon = stored.firstIndex(of: ":"),
              let tool = AgentHistoryTool(rawValue: String(stored[..<colon])) else { return nil }
        let id = String(stored[stored.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        self.init(tool: tool, sessionID: id)
    }
}

/// 置顶按哪台主机分开记。
nonisolated enum AgentHistoryPinHost: Hashable, Sendable {
    /// 这台 Mac 自己（本机终端窗口）。
    case local
    /// 已保存的 SSH 主机（`ServerProfile.id`）。
    case server(UUID)
    /// 配对过的 Mac（握手报来的设备 ID：两端看到的是同一个，换了电脑名也不变）。
    case pairedMac(UUID)

    var stored: String {
        switch self {
        case .local: return "local"
        case .server(let id): return "server:" + id.uuidString
        case .pairedMac(let id): return "mac:" + id.uuidString
        }
    }
}

/// 存下来的一条：哪个会话、什么时候置顶的（超了上限丢最早置顶的那条要用）。顺序 = 数组的顺序 = 列表里的顺序。
nonisolated struct AgentHistoryPinEntry: Equatable, Sendable, Codable {
    let key: AgentHistoryPinKey
    let pinnedAt: Date

    init(key: AgentHistoryPinKey, pinnedAt: Date) {
        self.key = key
        self.pinnedAt = pinnedAt
    }

    private enum CodingKeys: String, CodingKey { case key, pinnedAt }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .key)
        guard let key = AgentHistoryPinKey(stored: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "unknown pin key")
        }
        self.key = key
        pinnedAt = try container.decode(Date.self, forKey: .pinnedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.stored, forKey: .key)
        try container.encode(pinnedAt, forKey: .pinnedAt)
    }
}

/// 拖到列表里的哪里（Mac 的侧栏）。
nonisolated enum AgentHistoryPinDrop: Equatable, Sendable {
    /// 进「置顶」一组，排在（不算被拖的那一行的）第 `index` 个位置。
    case pin(index: Int)
    /// 拖出了「置顶」一组：取消置顶。
    case unpin
    /// 没在置顶的行拖到下面：什么都不做。
    case none
}

/// 置顶的纯函数：顺序怎么变、列表里显示哪几个、拖到哪里算什么。两端共用，能单独测。
nonisolated enum AgentHistoryPinning {
    /// 每台主机最多记这么多；超了丢最早置顶的。
    static let limit = 200

    /// 列表里「置顶」一组的行：按置顶的顺序，在 `files`（已经按「显示」筛过的全部记录）里找；
    /// 还没读到信息的、不列出来的（桌面版起的）先不显示，找不到的（记录被删、这次没读出来）也不显示——但都不删存储。
    /// 同一个键对上好几份记录时取第一份（列表新的在前）。
    static func resolved(_ keys: [AgentHistoryPinKey], in files: [AgentHistorySessionFile],
                         metadata: [String: AgentHistorySessionMetadata]) -> [AgentHistorySessionFile] {
        guard !keys.isEmpty else { return [] }
        let first = AgentHistoryPinKey.firstFiles(in: files)
        return keys.compactMap { key in
            guard let file = first[key], let info = metadata[file.path], info.isListed else { return nil }
            return file
        }
    }

    /// 置顶（菜单）：排在最后；已经置顶的不动。
    static func appending(_ key: AgentHistoryPinKey, to entries: [AgentHistoryPinEntry], now: Date,
                          limit: Int = limit) -> [AgentHistoryPinEntry] {
        guard !entries.contains(where: { $0.key == key }) else { return entries }
        return trimmed(entries + [AgentHistoryPinEntry(key: key, pinnedAt: now)], keeping: key, limit: limit)
    }

    static func removing(_ key: AgentHistoryPinKey, from entries: [AgentHistoryPinEntry]) -> [AgentHistoryPinEntry] {
        entries.filter { $0.key != key }
    }

    /// 拖进「置顶」一组（或在组里拖动）：放到列表里看得见的第 `index` 个位置（`visible` 是组里现在显示的行，
    /// `index` 按去掉被拖的那一行之后数）。存储里还有看不见的（这次没列出来的），它们之间的先后不变：
    /// 落在第 n 行前面就插到那一行前面，落在最后就插到最后一个看得见的后面。已经置顶的保留原来的置顶时间。
    static func placing(_ key: AgentHistoryPinKey, at index: Int, visible: [AgentHistoryPinKey],
                        in entries: [AgentHistoryPinEntry], now: Date, limit: Int = limit) -> [AgentHistoryPinEntry] {
        let entry = entries.first { $0.key == key } ?? AgentHistoryPinEntry(key: key, pinnedAt: now)
        var result = entries.filter { $0.key != key }
        let others = visible.filter { $0 != key }
        let position: Int
        if index < others.count, let before = result.firstIndex(where: { $0.key == others[max(index, 0)] }) {
            position = before
        } else if let last = others.last, let after = result.firstIndex(where: { $0.key == last }) {
            position = after + 1
        } else {
            position = index <= 0 ? 0 : result.count
        }
        result.insert(entry, at: position)
        return trimmed(result, keeping: key, limit: limit)
    }

    /// 超了上限：丢最早置顶的（刚放进去的那条不丢）。
    static func trimmed(_ entries: [AgentHistoryPinEntry], keeping key: AgentHistoryPinKey,
                        limit: Int) -> [AgentHistoryPinEntry] {
        var result = entries
        while result.count > max(limit, 1) {
            guard let oldest = result.indices.filter({ result[$0].key != key })
                .min(by: { result[$0].pinnedAt < result[$1].pinnedAt }) else { break }
            result.remove(at: oldest)
        }
        return result
    }

    /// 拖动落在哪：`y` 在「置顶」一组的下沿（`pinnedBottom`；还没有置顶时是那条「拖到这里置顶」的下沿）以上就是进置顶，
    /// 位置按组里别的行（不含被拖的那一行）的中线数；以下是拖出去——被拖的本来就置顶着就是取消，否则什么都不做。
    static func drop(at y: CGFloat, pinnedBottom: CGFloat?, otherRowMidYs: [CGFloat],
                     draggedIsPinned: Bool) -> AgentHistoryPinDrop {
        if let pinnedBottom, y <= pinnedBottom {
            return .pin(index: otherRowMidYs.filter { $0 < y }.count)
        }
        return draggedIsPinned ? .unpin : .none
    }
}

/// 一台主机上置顶的会话。存本机的 `UserDefaults`（`DefaultsKey.agentHistoryPinnedSessions`），**不进 iCloud / 局域网同步**：
/// 会话 ID 是那台主机上的东西，别的设备上未必列得出来，也没必要让一台设备的置顶改另一台的。
///
/// 存的是「主机 → 有序的（工具 + 会话 ID、置顶时间）」，一个键里放全部主机（JSON）。列表暂时找不到的不删
/// （一次没读出来不能把置顶清空）；每台主机至多 `AgentHistoryPinning.limit` 条。
///
/// 同一台主机开着两个列表（两扇窗口）时，一边改了另一边跟着变：听 `UserDefaults.didChangeNotification` 重读。
@MainActor
@Observable
final class AgentHistoryPins {
    let host: AgentHistoryPinHost
    /// 按列表里的顺序。
    private(set) var keys: [AgentHistoryPinKey] = []
    @ObservationIgnored private var entries: [AgentHistoryPinEntry] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(host: AgentHistoryPinHost, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.host = host
        self.defaults = defaults
        self.now = now
        reload()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func isPinned(_ key: AgentHistoryPinKey) -> Bool { keys.contains(key) }

    func isPinned(_ file: AgentHistorySessionFile) -> Bool { isPinned(AgentHistoryPinKey(file)) }

    /// 置顶（菜单）：排在「置顶」一组的最后。
    func pin(_ key: AgentHistoryPinKey) {
        apply(AgentHistoryPinning.appending(key, to: entries, now: now()))
    }

    func unpin(_ key: AgentHistoryPinKey) {
        apply(AgentHistoryPinning.removing(key, from: entries))
    }

    func toggle(_ file: AgentHistorySessionFile) {
        let key = AgentHistoryPinKey(file)
        if isPinned(key) { unpin(key) } else { pin(key) }
    }

    /// 拖进 / 在组里拖到第 `index` 个位置（见 `AgentHistoryPinning.placing`）。
    func place(_ key: AgentHistoryPinKey, at index: Int, visible: [AgentHistoryPinKey]) {
        apply(AgentHistoryPinning.placing(key, at: index, visible: visible, in: entries, now: now()))
    }

    /// 从偏好里重读（别的窗口改过）。
    func reload() {
        entries = Self.load(host, from: defaults)
        let next = entries.map(\.key)
        if next != keys { keys = next }
    }

    private func apply(_ next: [AgentHistoryPinEntry]) {
        guard next != entries else { return }
        entries = next
        keys = next.map(\.key)
        Self.save(next, for: host, to: defaults)
    }

    // MARK: 存储

    nonisolated static func load(_ host: AgentHistoryPinHost, from defaults: UserDefaults) -> [AgentHistoryPinEntry] {
        decode(defaults.data(forKey: DefaultsKey.agentHistoryPinnedSessions))[host.stored] ?? []
    }

    nonisolated static func save(_ entries: [AgentHistoryPinEntry], for host: AgentHistoryPinHost, to defaults: UserDefaults) {
        var all = decode(defaults.data(forKey: DefaultsKey.agentHistoryPinnedSessions))
        all[host.stored] = entries.isEmpty ? nil : entries
        if all.isEmpty {
            defaults.removeObject(forKey: DefaultsKey.agentHistoryPinnedSessions)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: DefaultsKey.agentHistoryPinnedSessions)
        }
    }

    /// 坏掉的整份按空的算；某一条认不出（以后删掉的工具）只跳过那一条。
    nonisolated static func decode(_ data: Data?) -> [String: [AgentHistoryPinEntry]] {
        guard let data, let raw = try? JSONDecoder().decode([String: [Lossy]].self, from: data) else { return [:] }
        return raw.mapValues { $0.compactMap(\.entry) }
    }

    private nonisolated struct Lossy: Decodable {
        let entry: AgentHistoryPinEntry?
        init(from decoder: any Decoder) throws {
            entry = try? AgentHistoryPinEntry(from: decoder)
        }
    }
}
