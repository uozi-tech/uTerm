import XCTest
@testable import uTerm

@MainActor
final class EmptyServersStateTests: XCTestCase {
    func test_promptCaretDoesNotUseBlinkingTimerState() {
        let view = EmptyServersState(onNewServer: {})
        let storedPropertyNames = Set(Mirror(reflecting: view).children.compactMap(\.label))

        XCTAssertFalse(storedPropertyNames.contains("_caretOn"))
        XCTAssertFalse(storedPropertyNames.contains("blink"))
    }
}
