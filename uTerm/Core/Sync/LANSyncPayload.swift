import CryptoKit
import Foundation

nonisolated enum LANSyncDateCoding {
    /// Dates are metadata for sync, not event telemetry. Integer seconds make the
    /// digest stable across Codable round trips and device architectures.
    static func configure(encoder: JSONEncoder, decoder: JSONDecoder) {
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970.rounded())
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSince1970: try container.decode(Double.self))
        }
    }
}

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
    static func digestBytes(_ values: [Data]) -> String {
        var input = Data()
        for value in values {
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(value)
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    static func digestValue<T: Encodable>(_ value: T, encoder: JSONEncoder) throws -> String {
        let bytes = try encoder.encode(value)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ payload: LANSyncFullSnapshot, encoder: JSONEncoder) throws -> String {
        try digestValue(payload, encoder: encoder)
    }
}
