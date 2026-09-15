import AgentKit
import SwiftData
import XCTest
@testable import uTerm

/// v2 协议的三件事：长度前缀分帧、按记录数分片、`scope` 限定删除权威范围。
@MainActor
final class LANSyncProtocolTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ServerProfile.self, KnownHost.self, AIProvider.self, SSHKey.self,
                 ChatSession.self, ChatMessageRecord.self, ServerGroup.self,
                 ForwardingRule.self, QuickCommand.self, QuickCommandRun.self,
            configurations: config)
    }

    private func profile(_ id: UUID, name: String) -> LANSyncDataSnapshot.Profile {
        .init(id: id, name: name, host: "example.com", port: 22, username: "root",
              authMethodRaw: "password", keyID: nil, createdAt: Date(timeIntervalSince1970: 0),
              sortOrder: 0, group: nil, isPinned: false, lastConnectedAt: nil,
              sftpOnly: false, jumpHostID: nil)
    }

    private func session(_ id: UUID) -> LANSyncDataSnapshot.ChatSessionRecord {
        .init(id: id, title: "对话", createdAt: Date(timeIntervalSince1970: 0),
              updatedAt: Date(timeIntervalSince1970: 0), scopeID: nil)
    }

    private func snapshot(profiles: [LANSyncDataSnapshot.Profile] = [],
                          chatSessions: [LANSyncDataSnapshot.ChatSessionRecord] = [])
    -> LANSyncDataSnapshot {
        LANSyncDataSnapshot(profiles: profiles, groups: [], knownHosts: [], sshKeys: [],
                            providers: [], forwardingRules: [], quickCommands: [],
                            quickCommandRuns: [], chatSessions: chatSessions, chatMessages: [])
    }

    // MARK: - 分片

    func testSplitPacksRecordsUpToTheLimitPerChunk() {
        let snap = snapshot(profiles: (0..<10).map { profile(UUID(), name: "h\($0)") })
        let chunks = LANSyncDataStore.split(snap, limit: 4)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.recordCount), [4, 4, 2])
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.profiles.count }, 10)
    }

    /// 分片要跨类型装：一片装满 4 条就换下一片，不管这 4 条是不是同一张表。
    func testSplitFillsAcrossEntityTypes() {
        let snap = snapshot(profiles: (0..<3).map { profile(UUID(), name: "h\($0)") },
                            chatSessions: (0..<3).map { _ in session(UUID()) })
        let chunks = LANSyncDataStore.split(snap, limit: 4)

        XCTAssertEqual(chunks.map(\.recordCount), [4, 2])
        XCTAssertEqual(chunks[0].profiles.count, 3)
        XCTAssertEqual(chunks[0].chatSessions.count, 1)
        XCTAssertEqual(chunks[1].chatSessions.count, 2)
    }

    func testSplitOfEmptySnapshotProducesNoChunks() {
        XCTAssertTrue(LANSyncDataStore.split(.empty, limit: 8).isEmpty)
    }

    /// 分片送达后的结果必须与一次性合并整份快照等价。
    func testChunkedMergeMatchesWholeSnapshotMerge() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        let snap = snapshot(profiles: (0..<10).map { profile(UUID(), name: "h\($0)") })

        let merge = try store.beginMerge(scope: .all)
        for chunk in LANSyncDataStore.split(snap, limit: 3) { try merge.apply(chunk) }
        let report = try merge.finish()

        XCTAssertEqual(report.inserted, 10)
        XCTAssertEqual(report.deleted, 0)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<ServerProfile>()).count, 10)
    }

    /// 关键：删除只能等所有分片到齐。若逐片就删，第一片会把还没送到的记录全删掉。
    func testDeletionWaitsUntilEveryChunkHasArrived() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        let ids = (0..<6).map { _ in UUID() }
        _ = try store.merge(with: snapshot(profiles: ids.map { profile($0, name: "h") }))

        let merge = try store.beginMerge(scope: .all)
        let chunks = LANSyncDataStore.split(
            snapshot(profiles: ids.map { profile($0, name: "h") }), limit: 2)
        XCTAssertEqual(chunks.count, 3)
        try merge.apply(chunks[0])
        // 只灌了第一片就查：一条都不该被删。
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<ServerProfile>()).count, 6)
        try merge.apply(chunks[1])
        try merge.apply(chunks[2])
        let report = try merge.finish()

        XCTAssertEqual(report.deleted, 0)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<ServerProfile>()).count, 6)
    }

    /// 只按条数切不够：单条记录体量差着数量级。用一个**小的帧上限**驱动细切，
    /// 这样用例不绑死在 `maxFrameBytes` 的当前取值上。
    func testEncodedChunksSplitFatRecordsUntilEachFrameFits() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        let fat = (0..<8).map { _ in
            LANSyncDataSnapshot.QuickCommandRunRecord(
                id: UUID(), commandID: UUID(), startedAt: Date(timeIntervalSince1970: 0),
                durationMs: 1, resultsJSON: String(repeating: "x", count: 200_000),
                aiRecordJSON: nil)
        }
        let snap = LANSyncDataSnapshot(
            profiles: [], groups: [], knownHosts: [], sshKeys: [], providers: [],
            forwardingRules: [], quickCommands: [], quickCommandRuns: fat,
            chatSessions: [], chatMessages: [])
        _ = try store.merge(with: snap)

        let limit = 512 * 1024
        let frames = try store.encodedChunks(scope: .all, encoder: JSONEncoder(), limit: limit)

        XCTAssertGreaterThan(frames.count, 1, "1.6 MB 的数据应被切成多帧")
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.count, limit)
        }
        // 切出来的记录总数不能有增减。
        let decoded = try frames.map { try JSONDecoder().decode(LANSyncDataSnapshot.self, from: $0) }
        XCTAssertEqual(decoded.reduce(0) { $0 + $1.recordCount }, 8)
    }

    /// 细切到只剩一条仍超限时原样放行——让 send 报明确的错，好过悄悄丢数据。
    func testASingleOversizedRecordIsStillEmittedAsOneFrame() throws {
        let huge = LANSyncDataSnapshot(
            profiles: [], groups: [], knownHosts: [], sshKeys: [], providers: [],
            forwardingRules: [], quickCommands: [],
            quickCommandRuns: [.init(id: UUID(), commandID: UUID(),
                                     startedAt: Date(timeIntervalSince1970: 0), durationMs: 1,
                                     resultsJSON: String(repeating: "x", count: 64 * 1024),
                                     aiRecordJSON: nil)],
            chatSessions: [], chatMessages: [])
        var frames: [Data] = []

        try LANSyncDataStore.encodeFitting(huge, encoder: JSONEncoder(),
                                           limit: 1024, into: &frames)

        XCTAssertEqual(frames.count, 1, "只剩一条记录就不该再切")
        XCTAssertGreaterThan(frames[0].count, 1024)
    }

    // MARK: - scope

    /// 只同步 config 的设备**不能**删本地会话：那些历史是 iCloud 同步下来的，
    /// 对端没发不等于对端没有。
    func testConfigOnlyScopeLeavesLocalHistoryAlone() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        _ = try store.merge(with: snapshot(profiles: [profile(UUID(), name: "h")],
                                           chatSessions: [session(UUID())]))
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<ChatSession>()).count, 1)

        // 对端只发配置（且配置里那台主机也没了）
        let report = try store.merge(with: snapshot(profiles: []), scope: .config)

        XCTAssertEqual(report.deleted, 1, "配置里缺席的主机应被删除")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<ChatSession>()).count, 1,
                       "config-only 同步不得删除本地会话")
    }

    func testSnapshotWithoutHistoryScopeOmitsSessionsAndRuns() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        _ = try store.merge(with: snapshot(profiles: [profile(UUID(), name: "h")],
                                           chatSessions: [session(UUID())]))

        let configOnly = try store.snapshot(scope: .config)
        XCTAssertEqual(configOnly.profiles.count, 1)
        XCTAssertTrue(configOnly.chatSessions.isEmpty)
        XCTAssertTrue(configOnly.quickCommandRuns.isEmpty)

        let everything = try store.snapshot(scope: .all)
        XCTAssertEqual(everything.chatSessions.count, 1)
    }

    func testScopeIsCodableAsOptionSet() throws {
        let encoded = try JSONEncoder().encode(LANSyncScope.all)
        XCTAssertEqual(try JSONDecoder().decode(LANSyncScope.self, from: encoded), .all)
        XCTAssertTrue(LANSyncScope.all.contains(.history))
        XCTAssertFalse(LANSyncScope.config.contains(.history))
    }
}
