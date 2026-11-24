import XCTest
import NIOCore
import NIOSSH
@testable import uTerm
@testable import USSHKit

/// `SSHTransportFailure` 分类器：传输层失败（该重连）vs 应用层错误（该报错）。
final class SSHTransportFailureTests: XCTestCase {

    // MARK: USSHCore 的类型（迁移指南 7.1 那张表）

    func testDisconnectReasonsDecideNetworkLoss() {
        let reset = IOError(errnoCode: ECONNRESET, reason: "read")
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(SSHChannelError.connectionClosed(.transportError(reset))))
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(SSHChannelError.connectionClosed(.remoteClosed)))
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(
            SSHChannelError.connectionClosed(.keepAliveTimeout(unansweredProbes: 3))))
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(SSHClientError.connectionClosed(.remoteClosed)))
    }

    /// 本端关的（用户关了标签、App 主动断开）绝不能当成网络断了去重连。
    func testLocalCloseIsNotANetworkFailure() {
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHChannelError.connectionClosed(.localClose)))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHClientError.connectionClosed(.localClose)))
    }

    /// 重新交换密钥时对端换了主机密钥：要用户看，不能自动重连。
    func testHostKeyChangedDuringRekeyIsNotANetworkFailure() throws {
        let first = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        let second = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        let changed = SSHHostKeyChangedDuringRekey(previous: first, offered: second)
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHChannelError.connectionClosed(.transportError(changed))))
    }

    /// 只坏了一条通道、服务器拒绝了请求：连接本身没事（存活探测靠这个区分，误判会杀掉健康连接）。
    func testChannelLevelErrorsAreNotTransportFailures() {
        let rejected = SSHChannelOpenFailure(reasonCode: 4, description: "too many sessions")
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHChannelError.openRejected(rejected)))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHChannelError.channelFailed(ChannelError.eof)))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHChannelError.requestRejected(.exec)))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHChannelError.channelClosed))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(
            SSHCommandError.nonZeroExit(.exited(1), output: ByteBuffer())))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(CancellationError()))
    }

    func testConnectPhaseErrors() {
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(SSHClientError.connectTimeout(.seconds(1))))
        XCTAssertTrue(SSHTransportFailure.isTransportFailure(SSHClientError.handshakeTimeout(.seconds(1))))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHClientError.handshakeFailed(ChannelError.eof)))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHClientError.hostKeyValidationTimeout(.seconds(1))))
    }

    // MARK: 重试不会好的建连失败

    func testPermanentConnectFailuresStopReconnecting() {
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(
            SSHConnection.SSHConnectionError.authenticationFailed("服务器拒绝了密码")))
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(
            SSHConnection.SSHConnectionError.handshakeFailed("no common algorithm")))
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(
            SSHConnection.SSHConnectionError.hostKeyRejected("用户拒绝")))
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(USSHKit.SSHConnectionError.handshakeFailed("x")))
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(SSHClientError.handshakeFailed(ChannelError.eof)))

        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(
            SSHConnection.SSHConnectionError.connectFailed("无法连接")))
        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(
            SSHConnection.SSHConnectionError.jumpHostFailed("跳板机断了")))
        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(SSHClientError.connectTimeout(.seconds(1))))
        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(CancellationError()))
    }

    /// 认证 / 主机密钥 / 握手失败时服务器在应答：不是传输层断了。
    func testPermanentConnectFailuresAreNotTransportFailures() {
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(
            SSHConnection.SSHConnectionError.authenticationFailed("connection closed")))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(
            SSHConnection.SSHConnectionError.handshakeFailed("connection closed")))
    }

    // MARK: NIO / errno

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
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SFTPError.invalidResponse("bad")))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(
            SFTPError.status(code: .noSuchFile, message: "No such file", languageTag: "")))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SFTPError.shortRead(expected: 10, actual: 5)))
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
    }
}
