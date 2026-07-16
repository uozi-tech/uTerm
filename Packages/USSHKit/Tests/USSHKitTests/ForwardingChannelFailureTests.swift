import XCTest
@_spi(uTermIntegration) @testable import USSHKit

final class ForwardingChannelFailureTests: XCTestCase {

    // MARK: - reason code 解析（NIOSSHError 诊断文本形如 "NIOSSHError.channelSetupRejected: Reason: 1 open failed"）

    func testAdministrativelyProhibitedReasonCodeParses() {
        XCTAssertEqual(
            SSHForwardingChannelFailure.rejectionKind(
                fromDiagnostics: "NIOSSHError.channelSetupRejected: Reason: 1 open failed"),
            .administrativelyProhibited
        )
    }

    func testConnectFailedReasonCodeParses() {
        XCTAssertEqual(
            SSHForwardingChannelFailure.rejectionKind(
                fromDiagnostics: "NIOSSHError.channelSetupRejected: Reason: 2 Connection refused"),
            .connectFailed
        )
    }

    func testUnknownReasonCodeFallsBackToOther() {
        XCTAssertEqual(
            SSHForwardingChannelFailure.rejectionKind(
                fromDiagnostics: "NIOSSHError.channelSetupRejected: Reason: 4 resource shortage"),
            .other
        )
        XCTAssertEqual(
            SSHForwardingChannelFailure.rejectionKind(fromDiagnostics: "no reason marker at all"),
            .other
        )
    }

    // MARK: - 错误归类

    func testForwardingTimeoutClassifiesAsTimeout() {
        let failure = SSHForwardingChannelFailure(classifying: ForwardingTimeoutError())
        XCTAssertEqual(failure.kind, .timeout)
        XCTAssertEqual(failure.detail, "开通道超时（上游无响应）")
    }

    func testUnrelatedErrorClassifiesAsOther() {
        struct Boom: Error {}
        let failure = SSHForwardingChannelFailure(classifying: Boom())
        XCTAssertEqual(failure.kind, .other)
    }

    // MARK: - 用户文案

    func testUserMessagesAreHumanReadable() {
        let timeout = SSHForwardingChannelFailure(kind: .timeout, detail: "d")
        XCTAssertTrue(timeout.userMessage(targetHost: "db.internal", targetPort: 5432).contains("db.internal:5432"))
        XCTAssertTrue(timeout.userMessage(targetHost: "db.internal", targetPort: 5432).contains("白名单"))

        let prohibited = SSHForwardingChannelFailure(kind: .administrativelyProhibited, detail: "d")
        XCTAssertTrue(prohibited.userMessage(targetHost: "db.internal", targetPort: 5432).contains("AllowTcpForwarding"))

        let connect = SSHForwardingChannelFailure(kind: .connectFailed, detail: "d")
        XCTAssertTrue(connect.userMessage(targetHost: "db.internal", targetPort: 5432).contains("无法连接目标 db.internal:5432"))
    }
}
