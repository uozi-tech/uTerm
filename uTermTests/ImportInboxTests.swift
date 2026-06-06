import XCTest
import Foundation
@testable import uTerm

@MainActor
final class ImportInboxTests: XCTestCase {
    func testEnqueueSetsPendingAndBumpsSerial() {
        let inbox = ImportInbox.shared
        _ = inbox.take()  // 清场（单例）
        let before = inbox.serial
        let p = ImportInbox.Pending(rows: [],
                                    dir: URL(fileURLWithPath: "/tmp/x"),
                                    stagingRoot: URL(fileURLWithPath: "/tmp/x"))
        inbox.enqueue(p)
        XCTAssertEqual(inbox.pending, p)
        XCTAssertEqual(inbox.serial, before + 1)
    }

    func testTakeClearsPending() {
        let inbox = ImportInbox.shared
        inbox.enqueue(.init(rows: [],
                            dir: URL(fileURLWithPath: "/tmp/y"),
                            stagingRoot: URL(fileURLWithPath: "/tmp/y")))
        let taken = inbox.take()
        XCTAssertNotNil(taken)
        XCTAssertNil(inbox.pending)
    }
}
