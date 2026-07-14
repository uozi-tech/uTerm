import Security
import XCTest
@testable import uTerm

final class KeychainAccessibilityTests: XCTestCase {
    func testSecretsRequireUnlockedDevice() {
        XCTAssertEqual(KeychainStore.accessibility,
                       kSecAttrAccessibleWhenUnlocked as String)
    }
}
