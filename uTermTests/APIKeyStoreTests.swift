import XCTest
@testable import uTerm

final class APIKeyStoreTests: XCTestCase {
    private let store = APIKeyStore(service: "com.uozi.uTerm.tests.apikey")

    override func tearDown() {
        try? store.delete()
        super.tearDown()
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(store.load())
    }

    func testSaveAndLoad() throws {
        try store.save("sk-ant-xxx")
        XCTAssertEqual(store.load(), "sk-ant-xxx")
    }

    func testOverwrite() throws {
        try store.save("old")
        try store.save("new")
        XCTAssertEqual(store.load(), "new")
    }

    func testDelete() throws {
        try store.save("sk-ant-xxx")
        try store.delete()
        XCTAssertNil(store.load())
    }
}
