import AgentKit
import Foundation
import SwiftData

/// 在本地 SwiftData 容器与局域网快照之间转换。
///
/// Mac 是同步权威端：移动端收到快照后整体替换本地副本。钥匙串正文不在这里出现，
/// 因而跨设备同步后仍需在目标设备单独录入 SSH / Provider 凭据。
@MainActor
final class LANSyncDataStore {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func snapshot() throws -> LANSyncDataSnapshot {
        let context = container.mainContext
        let profiles = try context.fetch(FetchDescriptor<ServerProfile>())
        let groups = try context.fetch(FetchDescriptor<ServerGroup>())
        let knownHosts = try context.fetch(FetchDescriptor<KnownHost>())
        let sshKeys = try context.fetch(FetchDescriptor<SSHKey>())
        let providers = try context.fetch(FetchDescriptor<AIProvider>())
        let rules = try context.fetch(FetchDescriptor<ForwardingRule>())
        let commands = try context.fetch(FetchDescriptor<QuickCommand>())
        let runs = try context.fetch(FetchDescriptor<QuickCommandRun>())
        let sessions = try context.fetch(FetchDescriptor<ChatSession>())
        let messages = try context.fetch(FetchDescriptor<ChatMessageRecord>())

        return LANSyncDataSnapshot(
            profiles: profiles.map { profile in
                .init(id: profile.id, name: profile.name, host: profile.host, port: profile.port,
                      username: profile.username, authMethodRaw: profile.authMethodRaw,
                      keyID: profile.keyID, createdAt: profile.createdAt, sortOrder: profile.sortOrder,
                      group: profile.group, isPinned: profile.isPinned,
                      lastConnectedAt: profile.lastConnectedAt, sftpOnly: profile.sftpOnly,
                      jumpHostID: profile.jumpHost?.id)
            },
            groups: groups.map { .init(name: $0.name, colorHex: $0.colorHex,
                                       isPinned: $0.isPinned, sortOrder: $0.sortOrder) },
            knownHosts: knownHosts.map { .init(id: $0.id, host: $0.host, port: $0.port,
                                               keyTypeRaw: $0.keyTypeRaw, keyBlob: $0.keyBlob,
                                               fingerprint: $0.fingerprint, firstTrustedAt: $0.firstTrustedAt) },
            sshKeys: sshKeys.map { .init(id: $0.id, name: $0.name, typeRaw: $0.typeRaw,
                                         bits: $0.bits, comment: $0.comment,
                                         fingerprint: $0.fingerprint, publicKey: $0.publicKey,
                                         createdAt: $0.createdAt, lastUsedAt: $0.lastUsedAt,
                                         hasPassphrase: $0.hasPassphrase) },
            providers: providers.map { .init(id: $0.id, name: $0.name, kindRaw: $0.kindRaw,
                                             baseURL: $0.baseURL, model: $0.model,
                                             sortOrder: $0.sortOrder, createdAt: $0.createdAt) },
            forwardingRules: rules.map { .init(id: $0.id, serverID: $0.serverID, name: $0.name,
                                               typeRaw: $0.typeRaw, listenHost: $0.listenHost,
                                               listenPort: $0.listenPort, destHost: $0.destHost,
                                               destPort: $0.destPort, destLabel: $0.destLabel,
                                               autostart: $0.autostart, launchAtAppStart: $0.launchAtAppStart,
                                               sortOrder: $0.sortOrder, createdAt: $0.createdAt) },
            quickCommands: commands.map { .init(id: $0.id, name: $0.name, serverIDs: $0.serverIDs,
                                                command: $0.command, intent: $0.intent,
                                                aiAssisted: $0.aiAssisted, lastRunAt: $0.lastRunAt,
                                                runCount: $0.runCount, sortOrder: $0.sortOrder,
                                                createdAt: $0.createdAt) },
            quickCommandRuns: runs.map { .init(id: $0.id, commandID: $0.commandID,
                                                startedAt: $0.startedAt, durationMs: $0.durationMs,
                                                resultsJSON: $0.resultsJSON, aiRecordJSON: $0.aiRecordJSON) },
            chatSessions: sessions.map { .init(id: $0.id, title: $0.title, createdAt: $0.createdAt,
                                               updatedAt: $0.updatedAt, scopeID: $0.scopeID) },
            chatMessages: messages.map { .init(id: $0.id, sessionID: $0.session?.id,
                                               roleRaw: $0.roleRaw, text: $0.text, createdAt: $0.createdAt,
                                               toolCallsJSON: $0.toolCallsJSON, toolCallID: $0.toolCallID,
                                               isError: $0.isError, displayText: $0.displayText,
                                               orderIndex: $0.orderIndex) })
    }

    func replace(with snapshot: LANSyncDataSnapshot) throws {
        let context = container.mainContext
        try deleteExistingData(in: context)

        for group in snapshot.groups {
            let model = ServerGroup(name: group.name, colorHex: group.colorHex,
                                    isPinned: group.isPinned, sortOrder: group.sortOrder)
            context.insert(model)
        }
        for item in snapshot.knownHosts {
            let model = KnownHost()
            model.id = item.id
            model.host = item.host
            model.port = item.port
            model.keyTypeRaw = item.keyTypeRaw
            model.keyBlob = item.keyBlob
            model.fingerprint = item.fingerprint
            model.firstTrustedAt = item.firstTrustedAt
            context.insert(model)
        }
        for item in snapshot.sshKeys {
            let model = SSHKey()
            model.id = item.id
            model.name = item.name
            model.typeRaw = item.typeRaw
            model.bits = item.bits
            model.comment = item.comment
            model.fingerprint = item.fingerprint
            model.publicKey = item.publicKey
            model.createdAt = item.createdAt
            model.lastUsedAt = item.lastUsedAt
            model.hasPassphrase = item.hasPassphrase
            context.insert(model)
        }
        for item in snapshot.providers {
            let model = AIProvider()
            model.id = item.id
            model.name = item.name
            model.kindRaw = item.kindRaw
            model.baseURL = item.baseURL
            model.model = item.model
            model.sortOrder = item.sortOrder
            model.createdAt = item.createdAt
            context.insert(model)
        }

        var profilesByID: [UUID: ServerProfile] = [:]
        for item in snapshot.profiles {
            let model = ServerProfile()
            model.id = item.id
            model.name = item.name
            model.host = item.host
            model.port = item.port
            model.username = item.username
            model.authMethodRaw = item.authMethodRaw
            model.keyID = item.keyID
            model.createdAt = item.createdAt
            model.sortOrder = item.sortOrder
            model.group = item.group
            model.isPinned = item.isPinned
            model.lastConnectedAt = item.lastConnectedAt
            model.sftpOnly = item.sftpOnly
            context.insert(model)
            profilesByID[item.id] = model
        }
        for item in snapshot.profiles {
            guard let jumpID = item.jumpHostID,
                  let profile = profilesByID[item.id] else { continue }
            profile.jumpHost = profilesByID[jumpID]
        }

        for item in snapshot.forwardingRules {
            let model = ForwardingRule()
            model.id = item.id
            model.serverID = item.serverID
            model.name = item.name
            model.typeRaw = item.typeRaw
            model.listenHost = item.listenHost
            model.listenPort = item.listenPort
            model.destHost = item.destHost
            model.destPort = item.destPort
            model.destLabel = item.destLabel
            model.autostart = item.autostart
            model.launchAtAppStart = item.launchAtAppStart
            model.sortOrder = item.sortOrder
            model.createdAt = item.createdAt
            context.insert(model)
        }
        for item in snapshot.quickCommands {
            let model = QuickCommand()
            model.id = item.id
            model.name = item.name
            model.serverIDs = item.serverIDs
            model.command = item.command
            model.intent = item.intent
            model.aiAssisted = item.aiAssisted
            model.lastRunAt = item.lastRunAt
            model.runCount = item.runCount
            model.sortOrder = item.sortOrder
            model.createdAt = item.createdAt
            context.insert(model)
        }
        for item in snapshot.quickCommandRuns {
            let model = QuickCommandRun()
            model.id = item.id
            model.commandID = item.commandID
            model.startedAt = item.startedAt
            model.durationMs = item.durationMs
            model.resultsJSON = item.resultsJSON
            model.aiRecordJSON = item.aiRecordJSON
            context.insert(model)
        }

        var sessionsByID: [UUID: ChatSession] = [:]
        for item in snapshot.chatSessions {
            let model = ChatSession()
            model.id = item.id
            model.title = item.title
            model.createdAt = item.createdAt
            model.updatedAt = item.updatedAt
            model.scopeID = item.scopeID
            context.insert(model)
            sessionsByID[item.id] = model
        }
        for item in snapshot.chatMessages {
            let model = ChatMessageRecord()
            model.id = item.id
            model.roleRaw = item.roleRaw
            model.text = item.text
            model.createdAt = item.createdAt
            model.toolCallsJSON = item.toolCallsJSON
            model.toolCallID = item.toolCallID
            model.isError = item.isError
            model.displayText = item.displayText
            model.orderIndex = item.orderIndex
            model.session = item.sessionID.flatMap { sessionsByID[$0] }
            context.insert(model)
        }
        try context.save()
    }

    private func deleteExistingData(in context: ModelContext) throws {
        try deleteAll(ChatMessageRecord.self, in: context)
        try deleteAll(ChatSession.self, in: context)
        try deleteAll(QuickCommandRun.self, in: context)
        try deleteAll(QuickCommand.self, in: context)
        try deleteAll(ForwardingRule.self, in: context)
        try deleteAll(ServerProfile.self, in: context)
        try deleteAll(KnownHost.self, in: context)
        try deleteAll(SSHKey.self, in: context)
        try deleteAll(AIProvider.self, in: context)
        try deleteAll(ServerGroup.self, in: context)
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        for item in try context.fetch(FetchDescriptor<T>()) {
            context.delete(item)
        }
    }
}
