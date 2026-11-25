import Darwin
import SwiftData
import XCTest
@testable import uTermMobile

/// iOS 终端连不上的时候说什么。
///
/// 起因（2026-11 真机）：对一台已经关掉的服务器（Docker 容器删了）点「重新连接」，又是一句读起来像「连接断了」
/// 的话、又让他重新连接，像在原地打转。开着代理 TUN 时连不上的地址先被代理接下、随即重置，NIO 报
/// `Connection reset by peer`，原样显示成「连接中断：…」；点重试得到一模一样的一句。
/// 另一件（同一台 Duo）：主机地址填成 `10.31.102`，系统按老式简写当成 `10.31.0.102`，真的连了过去。
@MainActor
final class MobileTerminalConnectFailureTests: XCTestCase {

    // MARK: - 重试之后

    /// 第一次失败照原样说；点「重试」/「重新连接」之后同样失败，说「仍然连不上：原因」。
    func testRetryAfterFailureSaysStillCannotConnect() async {
        let (controller, _) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, connectFailure: "10.31.0.102:2298 拒绝了连接"),
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, connectFailure: "10.31.0.102:2298 拒绝了连接"))
        let container = try! MobileFixtures.emptyContainer()
        let host = ServerProfile()
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        await MobileFakeTerminal.waitUntil { if case .failed = controller.state { true } else { false } }
        guard case .failed(let first) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertFalse(first.hasPrefix("仍然连不上"), first)

        controller.restart()
        await MobileFakeTerminal.waitUntil { if case .failed = controller.state { true } else { false } }
        guard case .failed(let second) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertTrue(second.hasPrefix("仍然连不上："), second)
        XCTAssertTrue(second.contains("拒绝了连接"), second)
    }

    // MARK: - 真的去连（产品的后端，127.0.0.1 不经代理 TUN）

    private var container: ModelContainer!
    private var profile: ServerProfile!
    private let relay = HostKeyChallengeRelay()

    private func makeHost(_ address: String, port: Int) throws {
        container = try MobileFixtures.emptyContainer()
        profile = ServerProfile()
        profile.name = "connect-failure"
        profile.host = address
        profile.port = port
        profile.username = "dev"
        profile.authMethod = .password
        container.mainContext.insert(profile)
        try container.mainContext.save()
        try KeychainStore().save("dev", profileID: profile.id, kind: .password)
        let id = profile.id
        addTeardownBlock { try? KeychainStore().delete(profileID: id, kind: .password) }
    }

    private func failure(of controller: MobileTerminalController, _ what: String) async -> String? {
        await MobileFakeTerminal.waitUntil(timeout: .seconds(20)) {
            if case .failed = controller.state { true } else { false }
        }
        guard case .failed(let message) = controller.state else {
            XCTFail("\(what)：应当失败，实际 \(controller.state)")
            return nil
        }
        return message
    }

    /// 服务器不在（端口没人监听）：说「拒绝了连接」；点重新连接后同样被拒，说「仍然连不上：…拒绝了连接」。
    /// 不出现「中断」「断开」，也不把 NIO 的 errno 原话丢给用户。
    func testServerGoneSaysRefusedAndRetrySaysStillCannotConnect() async throws {
        let port = try LoopbackPort.unused()
        try makeHost("127.0.0.1", port: port)
        let tab = TermTab(host: profile)
        let controller = tab.controller
        controller.start(profile: profile, container: container, relay: relay)
        let firstFailure = await failure(of: controller, "第一次连")
        let first = try XCTUnwrap(firstFailure)
        XCTAssertTrue(first.contains("拒绝了连接"), first)
        XCTAssertFalse(first.contains("errno"), first)
        XCTAssertFalse(first.contains("中断") || first.contains("断开"), first)

        XCTAssertTrue(controller.canReconnect)
        controller.restart()
        // 重试的结果与第一次同一句话时，等它真的重新失败一次（先离开 .failed 再回来）。
        await MobileFakeTerminal.waitUntil(timeout: .seconds(20)) {
            if case .failed(let m) = controller.state { m.hasPrefix("仍然连不上") } else { false }
        }
        let secondFailure = await failure(of: controller, "点重新连接之后")
        let second = try XCTUnwrap(secondFailure)
        XCTAssertTrue(second.hasPrefix("仍然连不上："), second)
        XCTAssertTrue(second.contains("拒绝了连接"), second)
        controller.close()
    }

    /// 已保存的旧主机地址像 IPv4 却不合法：连接前就拦下，说「不是有效的 IP 地址」，根本不拨号。
    /// `127.1` 交给系统会解析成 127.0.0.1——本机开着监听，证明一次都没连过来。
    func testSavedMalformedAddressIsRejectedBeforeDialing() async throws {
        let listener = try LoopbackPort.Listener()
        defer { listener.close() }
        try makeHost("127.1", port: listener.port)
        let tab = TermTab(host: profile)
        tab.controller.start(profile: profile, container: container, relay: relay)
        let failed = await failure(of: tab.controller, "不合法的地址")
        let message = try XCTUnwrap(failed)
        XCTAssertTrue(message.contains("不是有效的 IP 地址"), message)
        XCTAssertTrue(message.contains("127.1"), message)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(listener.acceptCount, 0, "不合法的地址不该真的拨出去")
        tab.controller.close()
    }

    // MARK: - 自动重连时说明为什么还没连上

    /// 会话留在主机上的后端自己重连、每次都被拒绝：「正在重新连接」下面说明上一次为什么没连上；接回后清掉。
    func testReconnectBannerReasonFollowsTheBackend() async throws {
        let backend = ScriptedReconnectingBackend()
        let controller = MobileTerminalController(transportFactory: MobileTerminalTransportFactory { _ in backend })
        controller.start(profile: ServerProfile(), container: try MobileFixtures.emptyContainer(), relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)

        backend.emit(reconnecting: true, failure: "10.0.0.1:22 拒绝了连接")
        let reported = await MobileFakeTerminal.waitUntil { controller.reconnectFailure != nil }
        XCTAssertTrue(reported)
        XCTAssertTrue(controller.isReconnecting)
        XCTAssertEqual(controller.reconnectFailure, "10.0.0.1:22 拒绝了连接")

        backend.emit(reconnecting: false, failure: nil)
        let cleared = await MobileFakeTerminal.waitUntil { controller.reconnectFailure == nil && !controller.isReconnecting }
        XCTAssertTrue(cleared)
        controller.close()
    }
}

/// 只会按测试的指令报「正在重连 / 为什么没连上」的后端。
private actor ScriptedReconnectingBackend: ReconnectingTerminalBackend {
    nonisolated let outputItems: AsyncStream<TerminalOutputItem>
    nonisolated let exitStream: AsyncStream<Void>
    nonisolated let reconnecting: AsyncStream<Bool>
    nonisolated let reconnectFailure: AsyncStream<String?>
    private nonisolated let reconnectingContinuation: AsyncStream<Bool>.Continuation
    private nonisolated let failureContinuation: AsyncStream<String?>.Continuation

    init() {
        outputItems = AsyncStream { _ in }
        exitStream = AsyncStream { _ in }
        (reconnecting, reconnectingContinuation) = AsyncStream<Bool>.makeStream()
        (reconnectFailure, failureContinuation) = AsyncStream<String?>.makeStream()
    }

    nonisolated func emit(reconnecting value: Bool, failure: String?) {
        reconnectingContinuation.yield(value)
        failureContinuation.yield(failure)
    }

    func connect() async throws {}
    func write(_ data: Data) async {}
    func resize(cols: UInt16, rows: UInt16) async {}
    func close() async {}
}

/// 本机回环上的端口：空着的、或者开着监听只数连进来几次。
enum LoopbackPort {
    static func unused() throws -> Int {
        let listener = try Listener()
        let port = listener.port
        listener.close()
        return port
    }

    final class Listener: @unchecked Sendable {
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
}
