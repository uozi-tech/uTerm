import XCTest
@testable import uTerm

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore(service: "com.uozi.uTerm.tests")
    private let id = UUID()

    override func tearDown() {
        try? store.delete(profileID: id, kind: .password)
        try? store.delete(profileID: id, kind: .passphrase)
        try? store.delete(profileID: id, kind: .privateKey)
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        try store.save("hunter2", profileID: id, kind: .password)
        XCTAssertEqual(try store.load(profileID: id, kind: .password), "hunter2")
    }

    func testOverwrite() throws {
        try store.save("old", profileID: id, kind: .password)
        try store.save("new", profileID: id, kind: .password)
        XCTAssertEqual(try store.load(profileID: id, kind: .password), "new")
    }

    func testLoadMissingReturnsNil() throws {
        XCTAssertNil(try store.load(profileID: id, kind: .privateKey))
    }

    func testDelete() throws {
        try store.save("secret", profileID: id, kind: .passphrase)
        try store.delete(profileID: id, kind: .passphrase)
        XCTAssertNil(try store.load(profileID: id, kind: .passphrase))
    }

    func testKindsAreIsolated() throws {
        try store.save("pw", profileID: id, kind: .password)
        try store.save("pk", profileID: id, kind: .privateKey)
        XCTAssertEqual(try store.load(profileID: id, kind: .password), "pw")
        XCTAssertEqual(try store.load(profileID: id, kind: .privateKey), "pk")
    }

    func testProfilesAreIsolated() throws {
        let id2 = UUID()
        defer { try? store.delete(profileID: id2, kind: .password) }
        try store.save("profile1", profileID: id, kind: .password)
        try store.save("profile2", profileID: id2, kind: .password)
        XCTAssertEqual(try store.load(profileID: id, kind: .password), "profile1")
        XCTAssertEqual(try store.load(profileID: id2, kind: .password), "profile2")
    }
}
