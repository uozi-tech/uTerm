import AgentKit
import Foundation

/// 局域网同步快照只包含可持久化的配置与历史数据，不包含钥匙串中的秘密正文。
nonisolated struct LANSyncDataSnapshot: Codable, Sendable {
    let profiles: [Profile]
    let groups: [Group]
    let knownHosts: [KnownHostRecord]
    let sshKeys: [SSHKeyRecord]
    let providers: [Provider]
    let forwardingRules: [ForwardingRuleRecord]
    let quickCommands: [QuickCommandRecord]
    let quickCommandRuns: [QuickCommandRunRecord]
    let chatSessions: [ChatSessionRecord]
    let chatMessages: [ChatMessageRecord]

    struct Profile: Codable, Sendable {
        let id: UUID
        let name: String
        let host: String
        let port: Int
        let username: String
        let authMethodRaw: String
        let keyID: UUID?
        let createdAt: Date
        let sortOrder: Int
        let group: String?
        let isPinned: Bool
        let lastConnectedAt: Date?
        let sftpOnly: Bool
        let jumpHostID: UUID?
    }

    struct Group: Codable, Sendable {
        let name: String
        let colorHex: String
        let isPinned: Bool
        let sortOrder: Int
    }

    struct KnownHostRecord: Codable, Sendable {
        let id: UUID
        let host: String
        let port: Int
        let keyTypeRaw: String
        let keyBlob: Data
        let fingerprint: String
        let firstTrustedAt: Date
    }

    struct SSHKeyRecord: Codable, Sendable {
        let id: UUID
        let name: String
        let typeRaw: String
        let bits: Int
        let comment: String
        let fingerprint: String
        let publicKey: String
        let createdAt: Date
        let lastUsedAt: Date?
        let hasPassphrase: Bool
    }

    struct Provider: Codable, Sendable {
        let id: UUID
        let name: String
        let kindRaw: String
        let baseURL: String
        let model: String
        let sortOrder: Int
        let createdAt: Date
    }

    struct ForwardingRuleRecord: Codable, Sendable {
        let id: UUID
        let serverID: UUID
        let name: String
        let typeRaw: String
        let listenHost: String
        let listenPort: Int
        let destHost: String?
        let destPort: Int
        let destLabel: String?
        let autostart: Bool
        let launchAtAppStart: Bool
        let sortOrder: Int
        let createdAt: Date
    }

    struct QuickCommandRecord: Codable, Sendable {
        let id: UUID
        let name: String
        let serverIDs: [UUID]
        let command: String
        let intent: String
        let aiAssisted: Bool
        let lastRunAt: Date?
        let runCount: Int
        let sortOrder: Int
        let createdAt: Date
    }

    struct QuickCommandRunRecord: Codable, Sendable {
        let id: UUID
        let commandID: UUID
        let startedAt: Date
        let durationMs: Int
        let resultsJSON: String
        let aiRecordJSON: String?
    }

    struct ChatSessionRecord: Codable, Sendable {
        let id: UUID
        let title: String
        let createdAt: Date
        let updatedAt: Date
        let scopeID: UUID?
    }

    struct ChatMessageRecord: Codable, Sendable {
        let id: UUID
        let sessionID: UUID?
        let roleRaw: String
        let text: String
        let createdAt: Date
        let toolCallsJSON: String
        let toolCallID: String
        let isError: Bool
        let displayText: String
        let orderIndex: Int
    }

    /// 本快照里的记录总数（分片按它计数）。
    var recordCount: Int {
        profiles.count + groups.count + knownHosts.count + sshKeys.count + providers.count
            + forwardingRules.count + quickCommands.count + quickCommandRuns.count
            + chatSessions.count + chatMessages.count
    }

    var isEmpty: Bool { recordCount == 0 }

    static let empty = LANSyncDataSnapshot(
        profiles: [], groups: [], knownHosts: [], sshKeys: [], providers: [],
        forwardingRules: [], quickCommands: [], quickCommandRuns: [],
        chatSessions: [], chatMessages: [])
}
