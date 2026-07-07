import XCTest
@testable import uTerm

/// `TunnelOutcome.suspectsInstantClose` 的判定：识别「开通道成功但后端瞬间 0 字节 EOF」，
/// 同时不误报正常连接 / 客户端主动断开 / 长连接。
final class TunnelOutcomeTests: XCTestCase {

    private func outcome(up: UInt64 = 0, down: UInt64 = 0, remoteFirst: Bool = true,
                         lifetime: Duration = .milliseconds(5)) -> TunnelOutcome {
        TunnelOutcome(bytesUp: up, bytesDown: down, remoteClosedFirst: remoteFirst, lifetime: lifetime)
    }

    func testRemoteInstantZeroByteCloseIsSuspect() {
        // 开通道成功 → 远端瞬间关、无任何回程数据 = 后端不可用的典型形。
        XCTAssertTrue(outcome().suspectsInstantClose)
    }

    func testClientSentRequestButNoReplyStillSuspect() {
        // 客户端先说话（Postgres SSLRequest，上行 8 字节）但后端 0 字节即关 → 仍疑似。
        XCTAssertTrue(outcome(up: 8, down: 0).suspectsInstantClose)
    }

    func testAnyDownstreamBytesNotSuspect() {
        // 有回程数据 = 转发正常（哪怕只有 1 字节的 'N'）→ 不疑似。
        XCTAssertFalse(outcome(up: 8, down: 1).suspectsInstantClose)
    }

    func testLocalClosedFirstNotSuspect() {
        // 客户端主动断开 = 本地先关 → 不疑似（不能把正常短连接误报）。
        XCTAssertFalse(outcome(remoteFirst: false).suspectsInstantClose)
    }

    func testLongLivedIdleCloseNotSuspect() {
        // 长连接空闲很久后被远端回收 → 不疑似（超过瞬间窗口）。
        XCTAssertFalse(outcome(lifetime: .seconds(30)).suspectsInstantClose)
    }
}
