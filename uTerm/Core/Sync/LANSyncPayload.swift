import CryptoKit
import Foundation

nonisolated struct LANSyncSecretRecord: Codable, Sendable {
    let account: String
    let value: String
}

nonisolated struct LANSyncFullSnapshot: Codable, Sendable {
    let data: LANSyncDataSnapshot
    let preferences: [LANSyncPreference]
    let secrets: [LANSyncSecretRecord]

    var recordCount: Int { data.recordCount }
    var secretCount: Int { secrets.count }
}

nonisolated struct LANSyncOffer: Codable, Sendable {
    let sessionID: UUID
    let deviceID: String
    let deviceName: String
    let recordCount: Int
    let preferenceCount: Int
    let secretCount: Int
    let chunkCount: Int
    let digest: String
    let includesSensitiveData: Bool
}

nonisolated struct LANSyncDecision: Codable, Sendable {
    let accepted: Bool
}

nonisolated struct LANSyncTransferChunk: Codable, Sendable {
    let index: Int
    let total: Int
    let data: LANSyncDataSnapshot
    let preferences: [LANSyncPreference]
    let secrets: [LANSyncSecretRecord]
}

nonisolated struct LANSyncTransferResult: Codable, Sendable {
    let succeeded: Bool
    let message: String
    let digest: String?
}

nonisolated enum LANSyncPayloadDigest {
    static func digest(_ payload: LANSyncFullSnapshot, encoder: JSONEncoder) throws -> String {
        let bytes = try encoder.encode(payload)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
