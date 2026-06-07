import XCTest
@testable import uTerm

final class AgentKeychainTests: XCTestCase {
    private let store = AgentKeychain(service: "com.uozi.uTerm.tests.agent")
    private let id = UUID()

    override func tearDown() {
        try? store.delete(for: id)
        super.tearDown()
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(store.load(for: id))
    }

    func testSaveAndLoad() throws {
        try store.save("sk-abc", for: id)
        XCTAssertEqual(store.load(for: id), "sk-abc")
    }

    func testOverwrite() throws {
        try store.save("old", for: id)
        try store.save("new", for: id)
        XCTAssertEqual(store.load(for: id), "new")
    }

    func testDelete() throws {
        try store.save("sk-abc", for: id)
        try store.delete(for: id)
        XCTAssertNil(store.load(for: id))
    }

    func testTwoIDsAreIndependent() throws {
        let a = UUID(); let b = UUID()
        defer { try? store.delete(for: a); try? store.delete(for: b) }
        try store.save("A-key", for: a)
        try store.save("B-key", for: b)
        XCTAssertEqual(store.load(for: a), "A-key")
        XCTAssertEqual(store.load(for: b), "B-key")
    }

    func testPurgeLegacyDoesNotThrow() {
        // 即便条目不存在也应静默通过。
        AgentKeychain.purgeLegacy(service: "com.uozi.uTerm.tests.agent.purge")
    }
}
