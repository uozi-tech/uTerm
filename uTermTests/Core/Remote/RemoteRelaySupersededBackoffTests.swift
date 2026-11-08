import XCTest
@testable import uTerm

/// 被顶替之后的退避：5 分钟起、每次翻倍、最多 1 小时，「重新连接」从头算。
final class RemoteRelaySupersededBackoffTests: XCTestCase {
    func test_standard_sequence_doubles_from_five_minutes_up_to_an_hour() {
        var backoff = RemoteRelaySupersededBackoff.standard
        let minutes = (0..<7).map { _ in backoff.take() / .seconds(60) }
        XCTAssertEqual(minutes, [5, 10, 20, 40, 60, 60, 60])
    }

    func test_reset_starts_over() {
        var backoff = RemoteRelaySupersededBackoff(initial: .seconds(1), maximum: .seconds(8))
        _ = backoff.take()
        _ = backoff.take()
        XCTAssertEqual(backoff.next, .seconds(4))
        backoff.reset()
        XCTAssertEqual(backoff.take(), .seconds(1))
    }
}
