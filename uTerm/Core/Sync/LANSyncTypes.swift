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

nonisolated struct LANSyncRequest: Codable, Sendable {
    let version: Int
    let deviceID: String
    let deviceName: String
    let pairingCode: String
    let preferences: [LANSyncPreference]
    let data: LANSyncDataSnapshot?
}

nonisolated struct LANSyncResponse: Codable, Sendable {
    let version: Int
    let accepted: Bool
    let message: String
    let preferences: [LANSyncPreference]
    let data: LANSyncDataSnapshot?
}

nonisolated enum LANSyncConstants {
    static let serviceType = "_uterm-sync._tcp"
    static let protocolVersion = 1
    static let maxMessageBytes = 512 * 1024
}
