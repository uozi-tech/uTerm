import XCTest
@testable import uTerm

final class WorkspaceWindowIDTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let original = WorkspaceWindowID(id: UUID(), serverID: UUID())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceWindowID.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSameServerWindowIDsAreEqual() {
        let serverID = UUID()
        let a = WorkspaceWindowID(serverID: serverID)
        let b = WorkspaceWindowID(serverID: serverID)
        XCTAssertEqual(a, b)
    }
}
