import XCTest
@testable import uTerm

final class PaneDragPayloadTests: XCTestCase {
    func testItemProviderRoundTrip() {
        let id = UUID()
        let provider = PaneDragPayload.itemProvider(paneID: id)
        let exp = expectation(description: "load")
        PaneDragPayload.load(from: provider) { loaded in
            XCTAssertEqual(loaded, id)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
