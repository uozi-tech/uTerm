import Darwin
import SwiftData
import XCTest
import USSHKit
@testable import uTerm

/// 服务器不在时连不上：按真实原因说（拒绝连接、握手前被断开、不可达、超时），重试之后说「仍然连不上：原因」。
///
/// 起因（2026-11 真机）：对一台已经关掉的服务器（Docker 容器删了）点「重新连接」，提示读起来又是「连接断了」——
/// 开着代理 TUN 时连不上的地址先被代理接下、随即重置，NIO 报的是 `Connection reset by peer`，原样显示成
/// 「SSH 连接失败：连接中断：read(descriptor:pointer:size:): Connection reset by peer) (errno: 54)」，
/// 像是连上了又断开；没有代理时是一串 `connection reset (error set): Connection refused) (errno: 61)`。
/// 点重试得到一模一样的一句，看不出这是重试的结果。
final class SSHConnectFailureTextTests: XCTestCase {

    // MARK: - 纯归类（用实测抓到的原话）

    func testClassifiesObservedNIOMessages() {
        let refused = "无法连接 127.0.0.1:2312：connection reset (error set): Connection refused) (errno: 61)"
        let reset = "连接中断：read(descriptor:pointer:size:): Connection reset by peer) (errno: 54)"
        XCTAssertEqual(SSHConnectFailureText.kind(of: refused), .refused)
        XCTAssertEqual(SSHConnectFailureText.kind(of: reset), .closedBeforeHandshake)
        XCTAssertEqual(SSHConnectFailureText.kind(of: SSHDisconnectReason.remoteClosed.userDescription), .closedBeforeHandshake)
        // 同一种情形有时报成写握手时通道已关（全量并行跑时实测）。
        XCTAssertEqual(SSHConnectFailureText.kind(of: "I/O on closed channel（NIOCore.ChannelError）"), .closedBeforeHandshake)
        XCTAssertEqual(SSHConnectFailureText.kind(of: "connect: Operation timed out (errno: 60)"), .timedOut)
        XCTAssertEqual(SSHConnectFailureText.kind(of: "connect: No route to host (errno: 65)"), .hostUnreachable)
        XCTAssertEqual(SSHConnectFailureText.kind(of: "connect: Network is unreachable (errno: 51)"), .networkUnreachable)
        XCTAssertNil(SSHConnectFailureText.kind(of: "登录阶段超时：30 秒 内未完成握手与认证"), "认不出的不猜")
        XCTAssertNil(SSHConnectFailureText.kind(of: "something (errno: 2)"))

        let refusedText = SSHConnectFailureText.refine(refused, host: "10.31.0.102", port: 2298)
        XCTAssertTrue(refusedText.contains("10.31.0.102:2298"), refusedText)
        XCTAssertTrue(refusedText.contains("拒绝了连接"), refusedText)
        XCTAssertFalse(refusedText.contains("errno"), "不要把 NIO 的原话丢给用户：\(refusedText)")
        let resetText = SSHConnectFailureText.refine(reset, host: "::1", port: 22)
        XCTAssertTrue(resetText.contains("[::1]:22"), resetText)
        XCTAssertTrue(resetText.contains("握手前"), resetText)
        XCTAssertFalse(resetText.contains("中断"), "不要读起来像「连上又断了」：\(resetText)")
        XCTAssertEqual(SSHConnectFailureText.refine("登录阶段超时", host: "h", port: 22), "登录阶段超时")
    }

    /// 重试之后的那句：「仍然连不上：<原因>」，原因去掉「SSH 连接失败：」那层前缀；各类原因各说各的。
    func testRetryMessageSaysStillCannotConnectWithTheReason() {
        let refused = SSHConnection.SSHConnectionError.connectFailed("10.0.0.1:22 拒绝了连接：那里没有在运行的 SSH 服务")
        XCTAssertEqual(TerminalConnectFailure.message(for: refused, retrying: false), refused.localizedDescription)
        let retried = TerminalConnectFailure.message(for: refused, retrying: true)
        XCTAssertTrue(retried.hasPrefix("仍然连不上："), retried)
        XCTAssertTrue(retried.contains("拒绝了连接"), retried)
        XCTAssertFalse(retried.contains("SSH 连接失败"), retried)

        let others: [any Error] = [
            SSHConnection.SSHConnectionError.authenticationFailed("密码不对"),
            SSHConnection.SSHConnectionError.hostKeyRejected("指纹变了"),
            SSHConnection.SSHConnectionError.handshakeFailed("没有共同算法"),
            InvalidHostAddressError(host: "10.31.102", isJumpHost: false),
        ]
        for error in others {
            let text = TerminalConnectFailure.message(for: error, retrying: true)
            XCTAssertTrue(text.hasPrefix("仍然连不上："), text)
            XCTAssertFalse(text.contains("断"), "原因不是断开，别说成断了：\(text)")
        }
    }

    // MARK: - 真的去连

    private func verifier() throws -> HostKeyVerifier {
        HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
    }

    private func connectError(port: Int) async throws -> SSHConnection.SSHConnectionError {
        do {
            _ = try await SSHClientFactory.connect(
                profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil),
                auth: .password(username: "tester", password: "x"), jumpHostAuth: nil,
                hostKeyVerifier: try verifier(), hostKeyApprover: { _ in false }, approvesInteractively: false)
            XCTFail("不该连上")
            throw CancellationError()
        } catch let error as SSHConnection.SSHConnectionError {
            return error
        }
    }

    /// 本机没人监听的端口：真的拒绝连接（127.0.0.1 不经代理 TUN）。说「拒绝了连接」，不是一串 errno。
    func testUnlistenedPortSaysRefused() async throws {
        let port = try FreeLoopbackPort.reserveAndRelease()
        let error = try await connectError(port: port)
        guard case .connectFailed(let detail) = error else { return XCTFail("\(error)") }
        XCTAssertTrue(detail.contains("拒绝了连接"), detail)
        XCTAssertTrue(detail.contains("127.0.0.1:\(port)"), detail)
        XCTAssertFalse(detail.contains("errno"), detail)
        XCTAssertFalse(SSHTransportFailure.isPermanentConnectFailure(error), "服务器可能马上回来：仍算可以再试的那类")
    }

    /// 端口接下连接随即断开（代理 TUN 替连不上的地址接下 TCP 时就是这样）：说「握手前就断开」，不说「连接中断」。
    func testAcceptThenCloseSaysClosedBeforeHandshake() async throws {
        let listener = try AcceptAndCloseListener()
        defer { listener.close() }
        let error = try await connectError(port: listener.port)
        guard case .connectFailed(let detail) = error else { return XCTFail("\(error)") }
        XCTAssertTrue(detail.contains("握手前"), detail)
        XCTAssertFalse(detail.contains("errno"), detail)
    }
}

/// 拿一个此刻空着的本机端口：绑上取端口号再关掉。
enum FreeLoopbackPort {
    static func reserveAndRelease() throws -> Int {
        let listener = try AcceptAndCloseListener()
        let port = listener.port
        listener.close()
        return port
    }
}

/// 本机回环上的监听：接下连接立刻关掉。
final class AcceptAndCloseListener: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(sock, 16) == 0 else { Darwin.close(sock); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        fd = sock
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread.detachNewThread {
            while true {
                let client = accept(sock, nil, nil)
                guard client >= 0 else { return }
                Darwin.close(client)
            }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}
