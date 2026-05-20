import XCTest
@testable import uTerm

final class WorkspaceWindowIDTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let original = WorkspaceWindowID(id: UUID(), serverID: UUID())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceWindowID.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSameServerDistinctWindowsAreNotEqual() {
        let serverID = UUID()
        let a = WorkspaceWindowID(id: UUID(), serverID: serverID)
        let b = WorkspaceWindowID(id: UUID(), serverID: serverID)
        XCTAssertNotEqual(a, b)   // 同一服务器、不同窗口 → 不相等
    }
}
