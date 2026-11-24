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
        let noCommon = SSHAlgorithmNegotiationFailure(category: .hostKey, clientOffer: ["ssh-ed25519"], serverOffer: ["ssh-dss"])
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(SSHClientError.noCommonAlgorithm(noCommon)))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(SSHClientError.noCommonAlgorithm(noCommon)))

        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(
            SSHConnection.SSHConnectionError.connectFailed("无法连接")))
        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(
            SSHConnection.SSHConnectionError.jumpHostFailed("跳板机断了")))
        // 经跳板机时，哪一跳的认证 / 主机密钥 / 握手失败都和直连一样不重试。
        for cause in [JumpHostFailureCause.authentication, .hostKey, .handshake] {
            XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(
                SSHConnection.SSHConnectionError.jumpHostFailed("跳板机拒绝了密码", cause: cause)))
            XCTAssertFalse(SSHTransportFailure.isTransportFailure(
                SSHConnection.SSHConnectionError.jumpHostFailed("connection closed", cause: cause)))
        }
        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(SSHClientError.connectTimeout(.seconds(1))))
        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(CancellationError()))
    }

    /// USSHKit 经跳板机的失败带着那一跳按直连规则归的类（`cause`）：只看它，不看文案。
    func testUSSHKitJumpHostFailureIsClassifiedByItsCause() {
        typealias Kit = USSHKit.SSHConnectionError
        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(Kit.jumpHostFailed("跳板机拒绝了密码")))
        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(
            Kit.jumpHostFailed("x", cause: .connectFailed("拒绝开 direct-tcpip"))))
        for cause: Kit in [.authenticationFailed("x"), .hostKeyRejected("x"), .handshakeFailed("x"),
                           .unsupportedAgentAuthentication] {
            XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(Kit.jumpHostFailed("x", cause: cause)), "\(cause)")
        }

        XCTAssertEqual(JumpHostFailureCause(nil), .unreachable)
        XCTAssertEqual(JumpHostFailureCause(.connectFailed("x")), .unreachable)
        XCTAssertEqual(JumpHostFailureCause(.authenticationFailed("x")), .authentication)
        XCTAssertEqual(JumpHostFailureCause(.unsupportedAgentAuthentication), .authentication)
        XCTAssertEqual(JumpHostFailureCause(.hostKeyRejected("x")), .hostKey)
        XCTAssertEqual(JumpHostFailureCause(.handshakeFailed("x")), .handshake)
    }

    /// 辅助进程把类别经 `SSHBridgeFailure.jumpHostCause` 交回 App；旧的辅助进程不带这个字段，按网络问题算。
    func testBridgeFailureCarriesTheJumpHostCause() throws {
        let failure = SSHBridgeFailure(kind: .jumpHost, message: "m", jumpHostCause: .hostKey)
        let decoded = try JSONDecoder().decode(SSHBridgeFailure.self, from: JSONEncoder().encode(failure))
        XCTAssertEqual(decoded.jumpHostCause, .hostKey)
        let old = try JSONDecoder().decode(SSHBridgeFailure.self, from: Data(#"{"kind":"jumpHost","message":"m"}"#.utf8))
        XCTAssertEqual(old.jumpHostCause, .unreachable)
        // 更新的辅助进程报了一个这版 App 还不认识的类别：整条失败照样解得开，按网络问题算。
        let newer = try JSONDecoder().decode(SSHBridgeFailure.self, from: Data(
            #"{"kind":"jumpHost","message":"m","jumpHostCause":"quantumEntanglement","localNetworkUnreachable":true}"#.utf8))
        XCTAssertEqual(newer.jumpHostCause, .unreachable)
        XCTAssertEqual(newer.message, "m")
        XCTAssertEqual(newer.localNetworkUnreachable, true)
    }

    /// 直连目标经 uterm-ssh 失败：类别经 `connectCause` 交回，App 认得出「重试也不会好」；文案与以前一字不差。
    func testDirectBridgeFailureCarriesItsCauseBothWaysAcrossVersions() throws {
        let decoder = JSONDecoder()
        // 新辅助进程 → 新 App。
        let fresh = SSHBridgeFailure(kind: .connect, message: "认证失败：服务器拒绝了密码",
                                     connectCause: .authentication, connectDetail: "服务器拒绝了密码")
        let decoded = try decoder.decode(SSHBridgeFailure.self, from: JSONEncoder().encode(fresh))
        let error = HeldSSHBackend.connectError(decoded)
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(error))
        XCTAssertEqual(error.errorDescription,
                       SSHConnection.SSHConnectionError.connectFailed("认证失败：服务器拒绝了密码").errorDescription,
                       "文案和以前（connectFailed 带前缀）一样")
        for (cause, permanent) in [(JumpHostFailureCause.hostKey, true), (.handshake, true), (.unreachable, false)] {
            let failure = SSHBridgeFailure(kind: .connect, message: "m", connectCause: cause, connectDetail: "m")
            XCTAssertEqual(SSHTransportFailure.isPermanentConnectFailure(HeldSSHBackend.connectError(failure)), permanent,
                           "\(cause)")
        }

        // 旧辅助进程（不带这两个字段）→ 新 App：照旧 connectFailed、不算永久。
        let old = try decoder.decode(SSHBridgeFailure.self, from: Data(#"{"kind":"connect","message":"认证失败：x"}"#.utf8))
        XCTAssertNil(old.connectCause)
        guard case .connectFailed("认证失败：x") = HeldSSHBackend.connectError(old) else { return XCTFail() }

        // 更新的辅助进程报了这版不认识的类别：照旧 connectFailed。
        let newer = try decoder.decode(SSHBridgeFailure.self, from: Data(
            #"{"kind":"connect","message":"m","connectCause":"somethingNew","connectDetail":"d"}"#.utf8))
        guard case .connectFailed("m") = HeldSSHBackend.connectError(newer) else { return XCTFail() }

        // 新辅助进程 → 旧 App：旧 App 的结构只认这几个字段，多出来的照样解得开。
        struct OldAppFailure: Decodable {
            enum Kind: String, Decodable { case jumpHost, connect }
            var kind: Kind
            var message: String
            var localNetworkUnreachable: Bool?
            var jumpHostCause: String?
        }
        let seenByOldApp = try decoder.decode(OldAppFailure.self, from: JSONEncoder().encode(fresh))
        XCTAssertEqual(seenByOldApp.message, "认证失败：服务器拒绝了密码")
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
