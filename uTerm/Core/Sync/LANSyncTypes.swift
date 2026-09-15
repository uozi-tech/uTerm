import Foundation

nonisolated enum LANSyncRole: Sendable {
    case sender
    case receiver
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

/// LAN 同步始终传输完整快照。保留 scope 类型是为了让数据存储层表达
///「配置 / 历史」边界，但网络协议固定使用 `.all`。
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
}

nonisolated enum LANSyncConstants {
    static let serviceType = "_uterm-sync._tcp"
    /// v3：发送方发起、接收方确认、CryptoKit AEAD 业务帧。
    static let protocolVersion = 3

    /// **单帧**上限：防对端一帧撑爆内存的防线，不是能力上限。
    /// 分片按编码后字节细切（见 `LANSyncDataStore.encodedChunks`），正常帧远小于此；
    /// 留这么宽是为了容下个别超大单条记录（多台广播的 `resultsJSON` 能到几十 KB）。
    static let maxFrameBytes = 8 * 1024 * 1024
    /// Plain JSON payload budget; encrypted envelopes use base64 and authentication overhead.
    static let maxChunkPayloadBytes = 5 * 1024 * 1024
    /// 一次同步允许接收的总字节，防止对端无限发下去。
    static let maxTotalBytes = 64 * 1024 * 1024
    /// 每个数据分片最多装多少条记录。按条数切而不是按字节切，
    /// 是因为编码后大小事先不知道；200 条 × 单条最大几十 KB 仍在单帧上限内。
    static let chunkRecordLimit = 200
    static let syncTimeoutSeconds: Double = 60
}
