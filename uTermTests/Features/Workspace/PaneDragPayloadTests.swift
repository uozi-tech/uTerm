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

    func testTabItemProviderRoundTrip() {
        let id = UUID()
        let provider = TabDragPayload.itemProvider(tabID: id)
        let exp = expectation(description: "load tab")
        TabDragPayload.load(from: provider) { loaded in
            XCTAssertEqual(loaded, id)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testFileBufferItemProviderRoundTrip() {
        let id = UUID()
        let provider = FileBufferDragPayload.itemProvider(bufferID: id)
        let exp = expectation(description: "load file buffer")
        FileBufferDragPayload.load(from: provider) { loaded in
            XCTAssertEqual(loaded, id)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testRemoteFileItemProviderRoundTrip() {
        let item = RemoteFileDragItem(
            scopeID: UUID(),
            path: "/home/user/a.txt",
            name: "a.txt",
            isDirectory: false)
        let provider = RemoteFileDragPayload.itemProvider(item: item)
        let exp = expectation(description: "load remote file")
        RemoteFileDragPayload.load(from: provider) { loaded in
            XCTAssertEqual(loaded, item)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
