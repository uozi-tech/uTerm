import AgentKit
import Foundation
import SwiftData

/// 在本地 SwiftData 容器与局域网快照之间转换。
///
/// Mac 是同步权威端，但**应用快照走最小增量**：按主键逐条比对，只写真正变化的字段，
/// 快照里没有的记录才删除。原先的「清空后整体重建」在开了 CloudKit 镜像之后不能用了 ——
/// 那等于把每条记录都当成删除 + 新建导出一遍，一次手动局域网同步会被放大成对所有设备的
/// 全量覆盖。逐字段守卫让未变化的对象根本不被标脏，CloudKit 也就不会为它产生任何导出。
///
/// 传输侧再叠一层：整份快照按 `LANSyncConstants.chunkRecordLimit` 拆成多帧发送
/// （见 `chunks(scope:)`），接收端用 `LANSyncMergeSession` 逐片合并、收齐后才统一删除。
///
/// 钥匙串正文不在这里出现，因而跨设备同步后仍需在目标设备单独录入 SSH / Provider 凭据。
@MainActor
final class LANSyncDataStore {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// 导出快照。`scope` 不含 `.history` 时，会话 / 消息 / 执行留痕直接不取 ——
    /// 它们是无界的那部分，而 iCloud 已经在同步它们。
    func snapshot(scope: LANSyncScope = .all) throws -> LANSyncDataSnapshot {
        let context = container.mainContext
        let wantsHistory = scope.contains(.history)
        let profiles = try context.fetch(FetchDescriptor<ServerProfile>())
        let groups = try context.fetch(FetchDescriptor<ServerGroup>())
        let knownHosts = try context.fetch(FetchDescriptor<KnownHost>())
        let sshKeys = try context.fetch(FetchDescriptor<SSHKey>())
        let providers = try context.fetch(FetchDescriptor<AIProvider>())
        let rules = try context.fetch(FetchDescriptor<ForwardingRule>())
        let commands = try context.fetch(FetchDescriptor<QuickCommand>())
        let runs = wantsHistory ? try context.fetch(FetchDescriptor<QuickCommandRun>()) : []
        let sessions = wantsHistory ? try context.fetch(FetchDescriptor<ChatSession>()) : []
        let messages = wantsHistory ? try context.fetch(FetchDescriptor<ChatMessageRecord>()) : []

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

    /// 导出并按记录数拆片，供长度前缀分帧逐帧发送。
    func chunks(scope: LANSyncScope = .all) throws -> [LANSyncDataSnapshot] {
        Self.split(try snapshot(scope: scope), limit: LANSyncConstants.chunkRecordLimit)
    }

    /// 拆片并编码成可直接发送的帧。
    ///
    /// 只按条数切是不够的：单条记录的体量差着数量级——一次多台广播的 `resultsJSON`
    /// 能到几十 KB，200 条就是几 MB，会撞上单帧上限。所以这里先按条数粗切，
    /// 再按**编码后的真实字节**对超限的片二分细切。
    func encodedChunks(scope: LANSyncScope = .all, encoder: JSONEncoder,
                       limit: Int = LANSyncConstants.maxFrameBytes) throws -> [Data] {
        var frames: [Data] = []
        for chunk in try chunks(scope: scope) {
            try Self.encodeFitting(chunk, encoder: encoder, limit: limit, into: &frames)
        }
        return frames
    }

    /// 编码一片；超过单帧上限就二分后各自再试，直到装得下或只剩一条记录。
    /// 单条记录自己就超限时原样放行——让 `send` 报一个明确的错，好过悄悄截断。
    nonisolated static func encodeFitting(_ chunk: LANSyncDataSnapshot,
                                          encoder: JSONEncoder,
                                          limit: Int = LANSyncConstants.maxFrameBytes,
                                          into frames: inout [Data]) throws {
        let data = try encoder.encode(chunk)
        guard data.count > limit, chunk.recordCount > 1 else {
            frames.append(data)
            return
        }
        for half in split(chunk, limit: max(1, chunk.recordCount / 2)) {
            try encodeFitting(half, encoder: encoder, limit: limit, into: &frames)
        }
    }

    /// 把一份快照按记录总数切成若干片。纯函数，便于单测边界。
    nonisolated static func split(_ snapshot: LANSyncDataSnapshot,
                                  limit: Int) -> [LANSyncDataSnapshot] {
        precondition(limit > 0, "分片大小必须为正")
        var profiles = snapshot.profiles[...]
        var groups = snapshot.groups[...]
        var knownHosts = snapshot.knownHosts[...]
        var sshKeys = snapshot.sshKeys[...]
        var providers = snapshot.providers[...]
        var rules = snapshot.forwardingRules[...]
        var commands = snapshot.quickCommands[...]
        var runs = snapshot.quickCommandRuns[...]
        var sessions = snapshot.chatSessions[...]
        var messages = snapshot.chatMessages[...]

        var chunks: [LANSyncDataSnapshot] = []
        var budget = limit
        func take<T>(_ slice: inout ArraySlice<T>) -> [T] {
            guard budget > 0, !slice.isEmpty else { return [] }
            let count = min(budget, slice.count)
            defer { budget -= count }
            let head = Array(slice.prefix(count))
            slice = slice.dropFirst(count)
            return head
        }

        while true {
            budget = limit
            // 显式按序取，不依赖函数实参的求值顺序。
            let p = take(&profiles)
            let g = take(&groups)
            let k = take(&knownHosts)
            let s = take(&sshKeys)
            let pr = take(&providers)
            let r = take(&rules)
            let c = take(&commands)
            let ru = take(&runs)
            let se = take(&sessions)
            let m = take(&messages)
            let chunk = LANSyncDataSnapshot(
                profiles: p, groups: g, knownHosts: k, sshKeys: s, providers: pr,
                forwardingRules: r, quickCommands: c, quickCommandRuns: ru,
                chatSessions: se, chatMessages: m)
            if chunk.isEmpty { break }
            chunks.append(chunk)
        }
        return chunks
    }

    /// 单片便捷路径：开一个会话、灌进去、收尾。
    @discardableResult
    func merge(with snapshot: LANSyncDataSnapshot,
               scope: LANSyncScope = .all) throws -> LANSyncMergeReport {
        let session = try beginMerge(scope: scope)
        try session.apply(snapshot)
        return try session.finish()
    }

    /// 开一次分片合并。收到的每一片调 `apply`，全部到齐后调 `finish`。
    func beginMerge(scope: LANSyncScope = .all) throws -> LANSyncMergeSession {
        try LANSyncMergeSession(context: container.mainContext, scope: scope)
    }
}

/// 一次（可能分多片的）局域网合并。
///
/// 为什么要有「会话」这层：删除只能等所有分片到齐才能做 —— 单看一片，缺席的记录
/// 分不清是「对端删了」还是「在下一片里」。所以 `apply` 只做 upsert 并记下见过的主键，
/// `finish` 才按 `scope` 统一删除。`scope` 也限定了删除的权威范围：只收到 config 的
/// 设备不会去动本地会话，否则会把 iCloud 同步下来的历史当成「对端没有」抹掉。
@MainActor
final class LANSyncMergeSession {
    private let context: ModelContext
    private let scope: LANSyncScope
    private var report = LANSyncMergeReport()

    private var groupsByName: [String: ServerGroup]
    private var knownHostsByID: [UUID: KnownHost]
    private var keysByID: [UUID: SSHKey]
    private var providersByID: [UUID: AIProvider]
    private var profilesByID: [UUID: ServerProfile]
    private var rulesByID: [UUID: ForwardingRule]
    private var commandsByID: [UUID: QuickCommand]
    private var runsByID: [UUID: QuickCommandRun]
    private var sessionsByID: [UUID: ChatSession]
    private var messagesByID: [UUID: ChatMessageRecord]

    private var seenGroups: Set<String> = []
    private var seenKnownHosts: Set<UUID> = []
    private var seenKeys: Set<UUID> = []
    private var seenProviders: Set<UUID> = []
    private var seenProfiles: Set<UUID> = []
    private var seenRules: Set<UUID> = []
    private var seenCommands: Set<UUID> = []
    private var seenRuns: Set<UUID> = []
    private var seenSessions: Set<UUID> = []
    private var seenMessages: Set<UUID> = []

    /// 关系留到 `finish` 再接：分片顺序不保证被引用的一端先到。
    private var pendingJumpHosts: [(profile: UUID, jumpHost: UUID?)] = []
    private var pendingMessageSessions: [(message: UUID, session: UUID?)] = []

    init(context: ModelContext, scope: LANSyncScope) throws {
        self.context = context
        self.scope = scope
        groupsByName = try Self.index(ServerGroup.self, in: context, key: \.name)
        knownHostsByID = try Self.index(KnownHost.self, in: context, key: \.id)
        keysByID = try Self.index(SSHKey.self, in: context, key: \.id)
        providersByID = try Self.index(AIProvider.self, in: context, key: \.id)
        profilesByID = try Self.index(ServerProfile.self, in: context, key: \.id)
        rulesByID = try Self.index(ForwardingRule.self, in: context, key: \.id)
        commandsByID = try Self.index(QuickCommand.self, in: context, key: \.id)
        runsByID = try Self.index(QuickCommandRun.self, in: context, key: \.id)
        sessionsByID = try Self.index(ChatSession.self, in: context, key: \.id)
        messagesByID = try Self.index(ChatMessageRecord.self, in: context, key: \.id)
    }

    /// 灌入一片：按主键 upsert，逐字段只写差异。
    func apply(_ chunk: LANSyncDataSnapshot) throws {
        for item in chunk.groups {
            seenGroups.insert(item.name)
            if let model = groupsByName[item.name] {
                let touched = [
                    write(model, \.colorHex, item.colorHex),
                    write(model, \.isPinned, item.isPinned),
                    write(model, \.sortOrder, item.sortOrder),
                ]
                if touched.contains(true) { report.updated += 1 }
            } else {
                let model = ServerGroup(name: item.name, colorHex: item.colorHex,
                                        isPinned: item.isPinned, sortOrder: item.sortOrder)
                context.insert(model)
                groupsByName[item.name] = model
                report.inserted += 1
            }
        }

        for item in chunk.knownHosts {
            seenKnownHosts.insert(item.id)
            let (model, isNew) = upsert(item.id, in: &knownHostsByID)
            let touched = [
                write(model, \.host, item.host),
                write(model, \.port, item.port),
                write(model, \.keyTypeRaw, item.keyTypeRaw),
                write(model, \.keyBlob, item.keyBlob),
                write(model, \.fingerprint, item.fingerprint),
                write(model, \.firstTrustedAt, item.firstTrustedAt),
            ]
            if touched.contains(true), !isNew { report.updated += 1 }
        }

        for item in chunk.sshKeys {
            seenKeys.insert(item.id)
            let (model, isNew) = upsert(item.id, in: &keysByID)
            let touched = [
                write(model, \.name, item.name),
                write(model, \.typeRaw, item.typeRaw),
                write(model, \.bits, item.bits),
                write(model, \.comment, item.comment),
                write(model, \.fingerprint, item.fingerprint),
                write(model, \.publicKey, item.publicKey),
                write(model, \.createdAt, item.createdAt),
                write(model, \.lastUsedAt, item.lastUsedAt),
                write(model, \.hasPassphrase, item.hasPassphrase),
            ]
            if touched.contains(true), !isNew { report.updated += 1 }
        }

        for item in chunk.providers {
            seenProviders.insert(item.id)
            let (model, isNew) = upsert(item.id, in: &providersByID)
            let touched = [
                write(model, \.name, item.name),
                write(model, \.kindRaw, item.kindRaw),
                write(model, \.baseURL, item.baseURL),
                write(model, \.model, item.model),
                write(model, \.sortOrder, item.sortOrder),
                write(model, \.createdAt, item.createdAt),
            ]
            if touched.contains(true), !isNew { report.updated += 1 }
        }

        for item in chunk.profiles {
            seenProfiles.insert(item.id)
            let (model, isNew) = upsert(item.id, in: &profilesByID)
            let touched = [
                write(model, \.name, item.name),
                write(model, \.host, item.host),
                write(model, \.port, item.port),
                write(model, \.username, item.username),
                write(model, \.authMethodRaw, item.authMethodRaw),
                write(model, \.keyID, item.keyID),
                write(model, \.createdAt, item.createdAt),
                write(model, \.sortOrder, item.sortOrder),
                write(model, \.group, item.group),
                write(model, \.isPinned, item.isPinned),
                write(model, \.lastConnectedAt, item.lastConnectedAt),
                write(model, \.sftpOnly, item.sftpOnly),
            ]
            if touched.contains(true), !isNew { report.updated += 1 }
            pendingJumpHosts.append((profile: item.id, jumpHost: item.jumpHostID))
        }

        for item in chunk.forwardingRules {
            seenRules.insert(item.id)
            let (model, isNew) = upsert(item.id, in: &rulesByID)
            let touched = [
                write(model, \.serverID, item.serverID),
                write(model, \.name, item.name),
                write(model, \.typeRaw, item.typeRaw),
                write(model, \.listenHost, item.listenHost),
                write(model, \.listenPort, item.listenPort),
                write(model, \.destHost, item.destHost),
                write(model, \.destPort, item.destPort),
                write(model, \.destLabel, item.destLabel),
                write(model, \.autostart, item.autostart),
                write(model, \.launchAtAppStart, item.launchAtAppStart),
                write(model, \.sortOrder, item.sortOrder),
                write(model, \.createdAt, item.createdAt),
            ]
            if touched.contains(true), !isNew { report.updated += 1 }
        }

        for item in chunk.quickCommands {
            seenCommands.insert(item.id)
            let (model, isNew) = upsert(item.id, in: &commandsByID)
            let touched = [
                write(model, \.name, item.name),
                write(model, \.serverIDs, item.serverIDs),
                write(model, \.command, item.command),
                write(model, \.intent, item.intent),
                write(model, \.aiAssisted, item.aiAssisted),
                write(model, \.lastRunAt, item.lastRunAt),
                write(model, \.runCount, item.runCount),
                write(model, \.sortOrder, item.sortOrder),
                write(model, \.createdAt, item.createdAt),
            ]
            if touched.contains(true), !isNew { report.updated += 1 }
        }

        for item in chunk.quickCommandRuns {
            seenRuns.insert(item.id)
            let (model, isNew) = upsert(item.id, in: &runsByID)
            let touched = [
                write(model, \.commandID, item.commandID),
                write(model, \.startedAt, item.startedAt),
                write(model, \.durationMs, item.durationMs),
                write(model, \.resultsJSON, item.resultsJSON),
                write(model, \.aiRecordJSON, item.aiRecordJSON),
            ]
            if touched.contains(true), !isNew { report.updated += 1 }
        }

        for item in chunk.chatSessions {
            seenSessions.insert(item.id)
            let (model, isNew) = upsert(item.id, in: &sessionsByID)
            let touched = [
                write(model, \.title, item.title),
                write(model, \.createdAt, item.createdAt),
                write(model, \.updatedAt, item.updatedAt),
                write(model, \.scopeID, item.scopeID),
            ]
            if touched.contains(true), !isNew { report.updated += 1 }
        }

        for item in chunk.chatMessages {
            seenMessages.insert(item.id)
            let (model, isNew) = upsert(item.id, in: &messagesByID)
            let touched = [
                write(model, \.roleRaw, item.roleRaw),
                write(model, \.text, item.text),
                write(model, \.createdAt, item.createdAt),
                write(model, \.toolCallsJSON, item.toolCallsJSON),
                write(model, \.toolCallID, item.toolCallID),
                write(model, \.isError, item.isError),
                write(model, \.displayText, item.displayText),
                write(model, \.orderIndex, item.orderIndex),
            ]
            if touched.contains(true), !isNew { report.updated += 1 }
            pendingMessageSessions.append((message: item.id, session: item.sessionID))
        }
    }

    /// 收尾：接关系、按 scope 删除缺席记录、有改动才落盘。
    @discardableResult
    func finish() throws -> LANSyncMergeReport {
        for link in pendingJumpHosts {
            guard let model = profilesByID[link.profile] else { continue }
            let desired = link.jumpHost.flatMap { profilesByID[$0] }
            // 关系用引用比较：@Model 之间的相等性不保证按内容，identity 才是这里要的语义。
            if model.jumpHost !== desired {
                model.jumpHost = desired
                report.updated += 1
            }
        }
        for link in pendingMessageSessions {
            guard let model = messagesByID[link.message] else { continue }
            let desired = link.session.flatMap { sessionsByID[$0] }
            if model.session !== desired {
                model.session = desired
                report.updated += 1
            }
        }

        if scope.contains(.config) {
            report.deleted += prune(rulesByID, keeping: seenRules)
            report.deleted += prune(commandsByID, keeping: seenCommands)
            report.deleted += prune(profilesByID, keeping: seenProfiles)
            report.deleted += prune(knownHostsByID, keeping: seenKnownHosts)
            report.deleted += prune(keysByID, keeping: seenKeys)
            report.deleted += prune(providersByID, keeping: seenProviders)
            report.deleted += prune(groupsByName, keeping: seenGroups)
        }
        if scope.contains(.history) {
            report.deleted += prune(messagesByID, keeping: seenMessages)
            report.deleted += prune(sessionsByID, keeping: seenSessions)
            report.deleted += prune(runsByID, keeping: seenRuns)
        }

        // 全等时一次写入都不发生 —— CloudKit 自然也没有任何东西可导出。
        if report.isEmpty { return report }
        try context.save()
        return report
    }

    /// 放弃这次合并：把已灌入但未落盘的插入 / 修改回滚掉。
    ///
    /// 必须有这一步：分片是逐帧灌进共享的 `mainContext` 的，中途断线若直接丢掉会话，
    /// 那些对象仍留在上下文里，之后任何一次无关的 `save()`（用户改了台主机之类）
    /// 都会把**半份**同步结果顺手写进库。
    func cancel() {
        context.rollback()
    }

    // MARK: - 合并原语

    /// 按 id 取已有记录，没有就现造一条并登记。返回 `isNew` 用于区分「新增」与「更新」。
    private func upsert<M: LANSyncMergeable>(_ id: UUID,
                                             in index: inout [UUID: M]) -> (M, isNew: Bool) {
        if let existing = index[id] { return (existing, false) }
        let model = M()
        model.id = id
        context.insert(model)
        index[id] = model
        report.inserted += 1
        return (model, true)
    }

    /// 逐字段赋值：只有**真的不同**才写。
    ///
    /// 这不是省事，是省掉一次广播：SwiftData 一旦被赋值就把对象标脏，CloudKit 镜像
    /// 随后会把它当成一次真实改动导出给所有设备。守卫住这一行，未变化的记录就完全
    /// 不进入导出队列。
    private func write<M: AnyObject, V: Equatable>(
        _ model: M, _ keyPath: ReferenceWritableKeyPath<M, V>, _ value: V
    ) -> Bool {
        guard model[keyPath: keyPath] != value else { return false }
        model[keyPath: keyPath] = value
        return true
    }

    /// 按主键把某类型的现有记录索引成字典。
    private static func index<M: PersistentModel, K: Hashable>(
        _ type: M.Type, in context: ModelContext, key: KeyPath<M, K>
    ) throws -> [K: M] {
        var result: [K: M] = [:]
        for model in try context.fetch(FetchDescriptor<M>()) {
            result[model[keyPath: key]] = model
        }
        return result
    }

    /// 删除本次传输里缺席的记录，返回删除条数。
    private func prune<M: PersistentModel, K: Hashable>(
        _ existing: [K: M], keeping keep: Set<K>
    ) -> Int {
        var removed = 0
        for (key, model) in existing where !keep.contains(key) {
            context.delete(model)
            removed += 1
        }
        return removed
    }
}

/// 局域网合并需要「按 id 现造一条空记录」。参与同步的模型都满足这两条约束：
/// 无参构造 + 可写的 `UUID` 主键。（`ServerGroup` 以 `name` 作主键，不在此列。）
protocol LANSyncMergeable: PersistentModel {
    init()
    var id: UUID { get set }
}

extension KnownHost: LANSyncMergeable {}
extension SSHKey: LANSyncMergeable {}
extension AIProvider: LANSyncMergeable {}
extension ServerProfile: LANSyncMergeable {}
extension ForwardingRule: LANSyncMergeable {}
extension QuickCommand: LANSyncMergeable {}
extension QuickCommandRun: LANSyncMergeable {}
extension ChatSession: LANSyncMergeable {}
extension ChatMessageRecord: LANSyncMergeable {}

/// 一次局域网合并真正触及的记录数。`isEmpty` 为真表示两端已一致，未产生任何写入。
struct LANSyncMergeReport: Sendable, Equatable {
    var inserted = 0
    var updated = 0
    var deleted = 0

    var isEmpty: Bool { inserted == 0 && updated == 0 && deleted == 0 }

    var summary: String { "新增 \(inserted) · 更新 \(updated) · 删除 \(deleted)" }
}
