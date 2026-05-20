import XCTest
@testable import uTerm

final class WorkspaceSnapshotTests: XCTestCase {
    func testNodeSnapshotCodableRoundTrip() throws {
        let s1 = UUID(), s2 = UUID()
        let node = NodeSnapshot.split(
            direction: .horizontal, fraction: 0.4,
            first: .leaf(serverProfileID: s1, kind: .terminal),
            second: .leaf(serverProfileID: s2, kind: .terminal))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(NodeSnapshot.self, from: data)
        XCTAssertEqual(decoded, node)
    }

    func testWorkspaceSnapshotRoundTrip() throws {
        let snap = WorkspaceSnapshot(
            tabs: [
                TabSnapshot(title: "cluster", layout: .leaf(serverProfileID: UUID(), kind: .terminal)),
                TabSnapshot(title: "db", layout: .split(
                    direction: .vertical, fraction: 0.5,
                    first: .leaf(serverProfileID: UUID(), kind: .terminal),
                    second: .leaf(serverProfileID: UUID(), kind: .terminal))),
            ],
            activeTabIndex: 1)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testLeafDecodesLegacyJSONWithoutKindAsTerminal() throws {
        // Spec 1 时代的 leaf 快照没有 kind 字段。
        let legacy = #"{"leaf":{"serverProfileID":"\#(UUID().uuidString)"}}"#
        let decoded = try JSONDecoder().decode(NodeSnapshot.self, from: Data(legacy.utf8))
        guard case .leaf(_, let kind) = decoded else { return XCTFail("应为 leaf") }
        XCTAssertEqual(kind, .terminal)
    }

    func testLeafKindRoundTrip() throws {
        let node = NodeSnapshot.leaf(serverProfileID: UUID(), kind: .files)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(NodeSnapshot.self, from: data)
        XCTAssertEqual(decoded, node)
    }
}
