#if DEBUG
import XCTest
@testable import uTerm

@MainActor
final class TweaksModelTests: XCTestCase {
    func test_resolvedProfiles_real_returnsInput() {
        let m = TweaksModel()
        m.welcomeSource = .real
        let real = MockServerFactory.make(serverCount: 3, groupCount: 0,
                                          pinnedCount: 0, recentCount: 0, nameStyle: .normal)
        XCTAssertEqual(m.resolvedProfiles(real: real).count, 3)
    }

    func test_resolvedProfiles_empty_returnsEmpty() {
        let m = TweaksModel()
        m.welcomeSource = .empty
        let real = MockServerFactory.make(serverCount: 3, groupCount: 0,
                                          pinnedCount: 0, recentCount: 0, nameStyle: .normal)
        XCTAssertTrue(m.resolvedProfiles(real: real).isEmpty)
    }

    func test_resolvedProfiles_mock_usesKnobs() {
        let m = TweaksModel()
        m.welcomeSource = .mock
        m.serverCount = 6
        XCTAssertEqual(m.resolvedProfiles(real: []).count, 6)
    }
}
#endif
