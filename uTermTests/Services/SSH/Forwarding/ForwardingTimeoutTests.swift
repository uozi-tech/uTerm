import XCTest
@testable import uTerm

final class ForwardingTimeoutTests: XCTestCase {
    actor CleanupBox {
        private var cleaned = false
        func markCleaned() { cleaned = true }
        func isCleaned() -> Bool { cleaned }
    }

    func testTimeoutReturnsWithoutWaitingForNonCancellableOperation() async {
        let start = ContinuousClock.now

        do {
            try await withForwardingTimeout(.milliseconds(50)) {
                await Self.sleepIgnoringTaskCancellation(milliseconds: 300)
            }
            XCTFail("Expected timeout")
        } catch is ForwardingTimeoutError {
        } catch {
            XCTFail("Expected ForwardingTimeoutError, got \(error)")
        }

        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(1), "timeout must not wait for the operation task to finish")
    }

    func testLateSuccessRunsCleanupAfterTimeout() async {
        let box = CleanupBox()

        do {
            _ = try await withForwardingTimeout(
                .milliseconds(50),
                lateResultCleanup: { _ in await box.markCleaned() }
            ) {
                await Self.sleepIgnoringTaskCancellation(milliseconds: 150)
                return 1
            }
            XCTFail("Expected timeout")
        } catch is ForwardingTimeoutError {
        } catch {
            XCTFail("Expected ForwardingTimeoutError, got \(error)")
        }

        try? await Task.sleep(for: .milliseconds(300))
        let cleaned = await box.isCleaned()
        XCTAssertTrue(cleaned, "late successful resources should be cleaned after caller timed out")
    }

    private static func sleepIgnoringTaskCancellation(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}
