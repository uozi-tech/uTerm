import AgentKit
import SwiftData
import XCTest
@testable import uTerm

/// 局域网同步的应用路径必须是**最小增量**。
///
/// iCloud 镜像开着的时候，这里每多标脏一个对象，就多一条广播给所有设备的改动；
/// 早先「清空后整体重建」的实现会把一次手动同步放大成对全库的删除 + 新建。
/// 下面这些用例钉住两条底线：全等快照一次写入都不产生，变化的记录才被触及。
@MainActor
final class LANSyncDataStoreTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: ServerProfile.self, KnownHost.self, AIProvider.self, SSHKey.self,
                 ChatSession.self, ChatMessageRecord.self, ServerGroup.self,
                 ForwardingRule.self, QuickCommand.self, QuickCommandRun.self,
            configurations: config)
    }

    private func snapshot(profiles: [LANSyncDataSnapshot.Profile] = [],
                          groups: [LANSyncDataSnapshot.Group] = []) -> LANSyncDataSnapshot {
        LANSyncDataSnapshot(profiles: profiles, groups: groups, knownHosts: [], sshKeys: [],
                            providers: [], forwardingRules: [], quickCommands: [],
                            quickCommandRuns: [], chatSessions: [], chatMessages: [])
    }

    private func profile(_ id: UUID, name: String, host: String = "example.com",
                         jumpHostID: UUID? = nil) -> LANSyncDataSnapshot.Profile {
        .init(id: id, name: name, host: host, port: 22, username: "root",
              authMethodRaw: "password", keyID: nil,
              createdAt: Date(timeIntervalSince1970: 0), sortOrder: 0, group: nil,
              isPinned: false, lastConnectedAt: nil, sftpOnly: false, jumpHostID: jumpHostID)
    }

    private func profiles(in container: ModelContainer) throws -> [ServerProfile] {
        try container.mainContext.fetch(FetchDescriptor<ServerProfile>())
    }

    func testMergeIntoEmptyStoreInsertsRecords() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)

        let report = try store.merge(with: snapshot(profiles: [profile(UUID(), name: "web")]))

        XCTAssertEqual(report.inserted, 1)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.deleted, 0)
        XCTAssertEqual(try profiles(in: container).count, 1)
    }

    /// 两端已一致时不应产生任何写入——`save()` 都不该被调用。
    func testMergingIdenticalSnapshotTwiceWritesNothing() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        let snap = snapshot(profiles: [profile(UUID(), name: "web")],
                            groups: [.init(name: "prod", colorHex: "#ff0000",
                                           isPinned: true, sortOrder: 1)])

        _ = try store.merge(with: snap)
        let second = try store.merge(with: snap)

        XCTAssertTrue(second.isEmpty, "全等快照仍产生写入：\(second.summary)")
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    /// 回归守卫：未变化的记录必须是**同一个对象**，不能被删掉重建。
    func testUnchangedRecordsKeepTheirIdentity() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        let snap = snapshot(profiles: [profile(UUID(), name: "web")])

        _ = try store.merge(with: snap)
        let before = try XCTUnwrap(profiles(in: container).first)
        _ = try store.merge(with: snap)
        let after = try XCTUnwrap(profiles(in: container).first)

        XCTAssertTrue(before === after, "记录被重建了，说明又变回了清空重建")
    }

    func testOnlyTheChangedRecordIsTouched() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        let stable = UUID()
        let renamed = UUID()
        _ = try store.merge(with: snapshot(profiles: [profile(stable, name: "a"),
                                                      profile(renamed, name: "b")]))

        let report = try store.merge(with: snapshot(profiles: [profile(stable, name: "a"),
                                                               profile(renamed, name: "b2")]))

        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.inserted, 0)
        XCTAssertEqual(report.deleted, 0)
        let names = try profiles(in: container).sorted { $0.name < $1.name }.map(\.name)
        XCTAssertEqual(names, ["a", "b2"])
    }

    func testRecordsMissingFromSnapshotAreDeleted() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        let kept = UUID()
        _ = try store.merge(with: snapshot(profiles: [profile(kept, name: "a"),
                                                      profile(UUID(), name: "b")]))

        let report = try store.merge(with: snapshot(profiles: [profile(kept, name: "a")]))

        XCTAssertEqual(report.deleted, 1)
        XCTAssertEqual(try profiles(in: container).map(\.id), [kept])
    }

    func testJumpHostRelationIsLinkedByID() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        let bastion = UUID()
        let behind = UUID()

        _ = try store.merge(with: snapshot(profiles: [profile(bastion, name: "bastion"),
                                                      profile(behind, name: "app",
                                                              jumpHostID: bastion)]))

        let app = try XCTUnwrap(profiles(in: container).first { $0.id == behind })
        XCTAssertEqual(app.jumpHost?.id, bastion)
    }

    /// snapshot() 产出的快照再合并回去必须是空操作，否则两端会永远互相「有改动」。
    func testSnapshotRoundTripIsANoOp() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        let bastion = UUID()
        _ = try store.merge(with: snapshot(
            profiles: [profile(bastion, name: "bastion"),
                       profile(UUID(), name: "app", jumpHostID: bastion)],
            groups: [.init(name: "prod", colorHex: "#ff0000", isPinned: false, sortOrder: 0)]))

        let report = try store.merge(with: try store.snapshot())

        XCTAssertTrue(report.isEmpty, "往返后仍有写入：\(report.summary)")
    }

    func testGroupsAreMatchedByNameAndUpdatedInPlace() throws {
        let container = try makeContainer()
        let store = LANSyncDataStore(container: container)
        _ = try store.merge(with: snapshot(groups: [.init(name: "prod", colorHex: "#ff0000",
                                                          isPinned: false, sortOrder: 0)]))
        let before = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<ServerGroup>()).first)

        let report = try store.merge(with: snapshot(groups: [.init(name: "prod", colorHex: "#00ff00",
                                                                   isPinned: true, sortOrder: 0)]))

        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.inserted, 0)
        let after = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<ServerGroup>()).first)
        XCTAssertTrue(before === after)
        XCTAssertEqual(after.colorHex, "#00ff00")
        XCTAssertTrue(after.isPinned)
    }
}
