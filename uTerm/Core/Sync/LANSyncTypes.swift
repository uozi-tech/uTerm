import Foundation

nonisolated enum LANSyncRole: Sendable {
    case host
    case client
}

nonisolated enum LANSyncValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)

    private enum CodingKeys: String, CodingKey {
        case kind
        case string
        case bool
        case integer
    }

    private enum Kind: String, Codable {
        case string
        case bool
        case integer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .string))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .integer:
            self = .integer(try container.decode(Int.self, forKey: .integer))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .string)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .bool)
        case .integer(let value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .integer)
        }
    }
}

nonisolated struct LANSyncPreference: Codable, Equatable, Sendable {
    let key: String
    let value: LANSyncValue
    let modifiedAt: Date
}

/// 一次同步搬运哪些数据。
///
/// 拆开的理由：`config`（主机 / 分组 / 密钥元数据 / Provider / 转发规则 / 快捷命令定义）
/// 体量有界，重度用户也就 200 KB 上下；`history`（会话、消息、执行留痕）无界，实测
/// 500 条消息就 771 KB、4000 条 5.8 MB。而 iCloud 已经在持续同步历史，所以**被
/// CloudKit 覆盖的设备不必再从局域网搬一遍**。
///
/// `scope` 还决定删除的权威范围：只收到 config 的设备**不能**去删本地的会话，
/// 否则会把 iCloud 同步下来的历史当成「对端没有」而抹掉。
nonisolated struct LANSyncScope: OptionSet, Codable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let config = LANSyncScope(rawValue: 1 << 0)
    static let history = LANSyncScope(rawValue: 1 << 1)
    static let all: LANSyncScope = [.config, .history]
}

nonisolated struct LANSyncRequest: Codable, Sendable {
    let version: Int
    let deviceID: String
    let deviceName: String
    let pairingCode: String
    let preferences: [LANSyncPreference]
    /// 该设备想要的范围。已被 CloudKit 覆盖时只要 `config`。
    let scope: LANSyncScope
}

/// 响应的**第一帧**：握手结论 + 偏好 + 后面还有几帧数据。
/// 数据本身按 `LANSyncConstants.chunkRecordLimit` 拆成若干 `LANSyncDataSnapshot` 分片单独发。
nonisolated struct LANSyncResponseHeader: Codable, Sendable {
    let version: Int
    let accepted: Bool
    let message: String
    let preferences: [LANSyncPreference]
    /// 本次实际发送的范围（可能窄于请求，例如对端也没有历史）。
    let scope: LANSyncScope
    /// 紧随其后的数据分片帧数。0 表示没有数据要发。
    let chunkCount: Int
}

nonisolated enum LANSyncConstants {
    static let serviceType = "_uterm-sync._tcp"
    /// v2：换行分帧 → 长度前缀分帧，单条响应 → header + N 个数据分片。
    static let protocolVersion = 2

    /// **单帧**上限：防对端一帧撑爆内存的防线，不是能力上限。
    /// 分片按编码后字节细切（见 `LANSyncDataStore.encodedChunks`），正常帧远小于此；
    /// 留这么宽是为了容下个别超大单条记录（多台广播的 `resultsJSON` 能到几十 KB）。
    static let maxFrameBytes = 8 * 1024 * 1024
    /// 一次同步允许接收的总字节，防止对端无限发下去。
    static let maxTotalBytes = 64 * 1024 * 1024
    /// 每个数据分片最多装多少条记录。按条数切而不是按字节切，
    /// 是因为编码后大小事先不知道；200 条 × 单条最大几十 KB 仍在单帧上限内。
    static let chunkRecordLimit = 200
    /// 一次同步从发出请求到收完最后一帧的上限。
    /// 没有它，对端不按新协议应答（例如还没升级的旧版 Mac）就会让客户端一直停在「同步中…」。
    static let syncTimeoutSeconds: Double = 30
}
