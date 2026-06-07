import XCTest
@testable import uTerm

final class TransferProgressEmitterTests: XCTestCase {
    func testLargeTransfersEmitFirstChunkBeforePercentChanges() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var emitter = TransferProgressEmitter(
            totalBytes: Int64(4) * 1024 * 1024 * 1024,
            minimumInterval: 0.25)

        XCTAssertTrue(emitter.shouldEmit(bytesDone: 0, at: start))
        XCTAssertTrue(emitter.shouldEmit(bytesDone: 32 * 1024,
                                         at: start.addingTimeInterval(0.01)))
        XCTAssertFalse(emitter.shouldEmit(bytesDone: 64 * 1024,
                                          at: start.addingTimeInterval(0.10)))
        XCTAssertTrue(emitter.shouldEmit(bytesDone: 96 * 1024,
                                         at: start.addingTimeInterval(0.27)))
    }

    func testCompletionAlwaysEmitsWhenTotalKnown() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let total = Int64(8 * 1024 * 1024)
        var emitter = TransferProgressEmitter(totalBytes: total, minimumInterval: 0.25)

        XCTAssertTrue(emitter.shouldEmit(bytesDone: 0, at: start))
        XCTAssertTrue(emitter.shouldEmit(bytesDone: 32 * 1024,
                                         at: start.addingTimeInterval(0.01)))
        XCTAssertTrue(emitter.shouldEmit(bytesDone: total,
                                         at: start.addingTimeInterval(0.02)))
    }
}
