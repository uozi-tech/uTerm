import XCTest
@testable import uTerm

final class WorkspaceSnapshotTests: XCTestCase {
    func testNodeSnapshotCodableRoundTrip() throws {
        let s1 = UUID(), s2 = UUID()
        let node = NodeSnapshot.split(
            direction: .horizontal, fraction: 0.4,
            first: .leaf(serverProfileID: s1),
            second: .leaf(serverProfileID: s2))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(NodeSnapshot.self, from: data)
        XCTAssertEqual(decoded, node)
    }

    func testWorkspaceSnapshotRoundTrip() throws {
        let snap = WorkspaceSnapshot(
            tabs: [
                TabSnapshot(title: "cluster", layout: .leaf(serverProfileID: UUID())),
                TabSnapshot(title: "db", layout: .split(
                    direction: .vertical, fraction: 0.5,
                    first: .leaf(serverProfileID: UUID()),
                    second: .leaf(serverProfileID: UUID()))),
            ],
            activeTabIndex: 1)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testStoreSaveThenLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStore(directory: dir)
        let snap = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "t", layout: .leaf(serverProfileID: UUID()))],
            activeTabIndex: 0)
        try store.save(snap)
        XCTAssertEqual(store.load(), snap)
    }

    func testStoreLoadMissingReturnsNil() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertNil(WorkspaceStore(directory: dir).load())
    }

    func testStoreLoadCorruptReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("workspace.json"))
        XCTAssertNil(WorkspaceStore(directory: dir).load())
    }
}
