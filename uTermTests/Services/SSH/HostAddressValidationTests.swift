import Darwin
import SwiftData
import XCTest
@testable import uTerm

/// 像 IPv4 却不合法的主机地址：表单当场报错、不能保存 / 测试连接；连接前（已保存的旧主机、命令行、
/// 各处建连）同样拦下，不交给系统解析。
///
/// 起因（2026-11 真机）：用户把 `10.31.0.102` 填成了 `10.31.102`，系统按 `inet_aton` 的老式简写把最后一段当
/// 16 位，真的连上了 `10.31.0.102`；`256.1.1.1` 这类解析不了的会被当域名去查，开着代理 TUN 时查得到假 IP。
final class HostAddressValidationTests: XCTestCase {

    // MARK: - 纯判定

    /// 段数不对、超范围、前导 0（八进制）、十六进制、单个整数、多余的点：都不是有效的 IP 地址。
    func testRejectsMalformedDottedNumbers() {
        let invalid = [
            "10.31.0.1022", "256.1.1.1", "1.2.3", "1.2.3.4.5",
            "10.31.102",        // 少一段：inet_aton 当成 10.31.0.102
            "10.1",             // a.b：b 当 24 位
            "127.1",
            "167772161",        // 单个整数 = 10.0.0.1
            "0",
            "010.0.0.1",        // 前导 0 = 八进制
            "1.02.3.4",
            "0x0a.0.0.1", "0X7F.0.0.1", "0x7f000001", "0x",
            "1.2.3.4.",         // 结尾多一个点
            ".1.2.3", "1..2.3",
            " 10.31.102 ",      // 前后空白照样判
            "999.999.999.999", "1.2.3.256", "1234.1.1.1",
        ]
        for host in invalid {
            XCTAssertTrue(HostAddressValidation.isInvalidIPv4(host), "应判成不合法的 IP：\(host)")
        }
    }

    /// 合法的点分四段、域名（含数字的子域名、全数字标签但顶级域带字母）、IPv6、带方括号 / 端口的写法、空串都不误伤。
    func testLeavesValidAddressesAndDomainsAlone() {
        let fine = [
            "10.31.0.102", "0.0.0.0", "255.255.255.255", "127.0.0.1", "192.168.1.10", " 10.0.0.1 ",
            "localhost", "example.com", "web.example",
            "ec2-1-2-3-4.compute.amazonaws.com",
            "1.2.3.4.nip.io", "123.456.com", "10-31-0-102.sslip.io",
            "host1", "1host", "deadbeef", "abc.def", "0xhost.example",
            "1e100.net", "a.1.2.3",
            "::1", "fe80::1%en0", "[::1]", "[2001:db8::1]:22", "10.0.0.1:22",
            "", "   ",
        ]
        for host in fine {
            XCTAssertFalse(HostAddressValidation.isInvalidIPv4(host), "不该判成不合法的 IP：\(host)")
        }
    }

    func testMessageSaysItIsNotAValidIPAddress() {
        let message = HostAddressValidation.message(for: " 10.31.102 ")
        XCTAssertTrue(message.contains("10.31.102"), message)
        XCTAssertFalse(message.contains(" 10.31.102 "), "去掉前后空白再显示：\(message)")
        let jump = InvalidHostAddressError(host: "1.2.3", isJumpHost: true)
        XCTAssertNotEqual(jump.localizedDescription, InvalidHostAddressError(host: "1.2.3", isJumpHost: false).localizedDescription,
                          "跳板机要说明是跳板机的地址")
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(jump), "填错地址重试不会好：重连逻辑要停下来等用户")
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(jump))
    }

    // MARK: - 表单

    @MainActor
    func testFormFlagsAndBlocksInvalidAddress() {
        var draft = HostDraft()
        draft.name = "web"
        draft.username = "root"
        draft.password = "pw"
        for bad in ["10.31.102", "256.1.1.1", "1.2.3", "1.2.3.4.5", "10.31.0.1022"] {
            draft.host = bad
            XCTAssertNotNil(draft.hostError, "\(bad) 要当场报错")
            XCTAssertFalse(draft.isValid, "\(bad) 不能保存")
        }
        for good in ["10.31.0.102", "web.example", "ec2-1-2-3-4.compute.amazonaws.com", "::1"] {
            draft.host = good
            XCTAssertNil(draft.hostError, good)
            XCTAssertTrue(draft.isValid, good)
        }
    }

    // MARK: - 连接前

    /// `127.1` / `2130706433` / `0x7f.0.0.1` / `0177.0.0.1` 交给系统都会解析成 127.0.0.1。本机开一个监听，
    /// 证明这些地址根本走不到解析 / 建连：监听一次 accept 都收不到，抛的是类型化的 `InvalidHostAddressError`。
    @MainActor
    func testConnectRejectsBeforeResolvingOrDialing() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        for host in ["127.1", "2130706433", "0x7f.0.0.1", "0177.0.0.1"] {
            do {
                _ = try await SSHClientFactory.connect(
                    profile: SSHConnection.ProfileSnapshot(host: host, port: listener.port, jumpHost: nil),
                    auth: .password(username: "tester", password: "unused"), jumpHostAuth: nil,
                    hostKeyVerifier: verifier, hostKeyApprover: { _ in false }, approvesInteractively: false)
                XCTFail("\(host) 不该连上")
            } catch let error as InvalidHostAddressError {
                XCTAssertEqual(error.host, host)
                XCTAssertFalse(error.isJumpHost)
            } catch {
                XCTFail("\(host) 应在建连前报不合法的地址，实际：\(error)")
            }
        }
        // 跳板机的地址同样检查。
        do {
            _ = try await SSHClientFactory.connect(
                profile: SSHConnection.ProfileSnapshot(
                    host: "127.0.0.1", port: listener.port,
                    jumpHost: .init(host: "127.1", port: listener.port)),
                auth: .password(username: "tester", password: "unused"),
                jumpHostAuth: .password(username: "jumper", password: "unused"),
                hostKeyVerifier: verifier, hostKeyApprover: { _ in false }, approvesInteractively: false)
            XCTFail("跳板机地址不合法时不该连")
        } catch let error as InvalidHostAddressError {
            XCTAssertTrue(error.isJumpHost)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(listener.acceptCount, 0, "不合法的地址不该真的拨出去")

        // 对照：同一个监听，合法地址确实拨得到（证明上面的 0 次不是监听坏了）。
        _ = try? await SSHClientFactory.connect(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: listener.port, jumpHost: nil),
            auth: .password(username: "tester", password: "unused"), jumpHostAuth: nil,
            hostKeyVerifier: verifier, hostKeyApprover: { _ in false }, approvesInteractively: false,
            maximumPacketSize: SSHClientFactory.channelMaximumPacketSize)
        XCTAssertGreaterThan(listener.acceptCount, 0, "对照组：合法地址应该拨到本机监听")
    }
}

/// 本机回环上的 TCP 监听：接受连接后立刻关掉，只记次数。
private final class LoopbackListener: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var accepts = 0
    private var closed = false

    var acceptCount: Int { lock.withLock { accepts } }

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
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
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(sock, nil, nil)
                guard client >= 0 else { return }
                Darwin.close(client)
                guard let self else { return }
                self.lock.withLock { self.accepts += 1 }
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
