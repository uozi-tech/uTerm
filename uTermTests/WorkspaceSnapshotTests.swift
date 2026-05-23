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

    func test_decoding_ignoresLegacyKindField_terminal() throws {
        // pane-types 时代写入的 JSON 含 kind 字段；回退后应该忽略并照常重建。
        let json = #"""
        {"leaf":{"serverProfileID":"00000000-0000-0000-0000-000000000001","kind":"terminal"}}
        """#.data(using: .utf8)!
        let snap = try JSONDecoder().decode(NodeSnapshot.self, from: json)
        guard case .leaf(let id) = snap else { return XCTFail("expected leaf") }
        XCTAssertEqual(id.uuidString.lowercased(), "00000000-0000-0000-0000-000000000001")
    }

    func test_decoding_ignoresLegacyKindField_files() throws {
        // 老布局里有文件窗格，应退化为终端叶子（开发期可接受的退化）。
        let json = #"""
        {"leaf":{"serverProfileID":"00000000-0000-0000-0000-000000000002","kind":"files"}}
        """#.data(using: .utf8)!
        let snap = try JSONDecoder().decode(NodeSnapshot.self, from: json)
        guard case .leaf(let id) = snap else { return XCTFail("expected leaf") }
        XCTAssertEqual(id.uuidString.lowercased(), "00000000-0000-0000-0000-000000000002")
    }

    func test_encoding_omitsKindField() throws {
        let snap = NodeSnapshot.leaf(serverProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let data = try JSONEncoder().encode(snap)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("\"kind\""), "encoded JSON should not contain kind field, got: \(text)")
    }
}
