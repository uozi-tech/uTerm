import XCTest
import NIOCore
import Citadel
@testable import uTerm

/// `SSHTransportFailure` 分类器：传输层失败（该重连）vs 应用层错误（该报错）。
final class SSHTransportFailureTests: XCTestCase {

    // MARK: 类型精确匹配

    func testNIOClosedChannelErrorsAreTransportFailures() {
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(ChannelError.ioOnClosedChannel))
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(ChannelError.alreadyClosed))
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(ChannelError.outputClosed))
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(ChannelError.inputClosed))
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(ChannelError.eof))
    }

    func testNonTransportChannelErrorIsNot() {
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(ChannelError.operationUnsupported))
    }

    func testSFTPConnectionClosedIsTransportFailureButProtocolErrorsAreNot() {
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(SFTPError.connectionClosed))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SFTPError.invalidResponse))
    }

    func testPosixTransportErrnosMatch() {
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(
            IOError(errnoCode: ECONNRESET, reason: "read")))
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(
            IOError(errnoCode: EACCES, reason: "open")))
    }

    // MARK: 字符串兜底

    /// 真实 NIO 文案是 "I/O on closed channel"（"closed channel" 词序）。
    /// v1.2.3 的兜底词表只认 "channel closed" / "i/o channel close"，
    /// 正是「长时间待机断网后 SFTP 刷新永远无法恢复」的根因 —— 此用例钉死：
    /// 错误被多层 `"\(error)"` 字符串化、类型信息丢失后，这个词序也必须命中。
    func testStringifiedRealNIOMessageMatches() {
        let stringified = NSError(domain: "uTerm", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "上游错误：I/O on closed channel",
        ])
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(stringified))
    }

    // MARK: 应用层错误绝不触发重连

    func testApplicationLevelErrorsAreNotTransportFailures() {
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(NSError(
            domain: "uTerm", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"])))
        // channel 开不出来（如 MaxSessions 限制）= 对端在应答 = 传输活着；
        // 存活探测依赖这个区分，误判会杀掉健康连接。
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(
            CitadelError.channelCreationFailed))
    }
}
