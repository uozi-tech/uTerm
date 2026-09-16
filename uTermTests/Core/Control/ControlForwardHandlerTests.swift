import XCTest
import Darwin
import SwiftData
@testable import uTerm
@testable import USSHKit

/// 转发组 handler 的行为闸：规则解析四级 + 歧义、`forward-list` 的拼装、
/// `forward-stop` 幂等、`forward-start` 的端口占用预检。
///
/// 全程不建真连接：`list` / `stop` 用 `ForwardingCoordinator` 的测试 seam
/// （`setStatusForTesting` / `injectTrafficForTesting`）造运行态；`start` 只测
/// 「在把请求交给会话之前就被端口预检拦下」这一段。
@MainActor
final class ControlForwardHandlerTests: XCTestCase {

    private actor FakePool: ControlConnectionPooling {
        /// `forward-start` 拿到挑战后补记进来的那些（hostID, 挑战）。
        private(set) var recorded: [(UUID, HostKeyChallenge)] = []

        func executor(
            for host: HostConnectionSpec,
            maxLines: Int,
            maxBytes: Int
        ) async throws -> SSHCommandExecutor {
            throw ControlConnectError.connectFailed("测试替身不建连接")
        }
        func borrowSFTP(for host: HostConnectionSpec) async throws -> any SFTPProviding {
            throw ControlConnectError.connectFailed("测试替身不建连接")
        }

        func returnSFTP(_ session: any SFTPProviding, for hostID: UUID) async {}
        func disconnect(hostID: UUID) async {}
        func disconnectAll() async {}
        func heldHostIDs() async -> [UUID] { [] }
        func lastHostKeyChallenge(hostID: UUID) async -> HostKeyChallenge? {
            recorded.last { $0.0 == hostID }?.1
        }
        func recordChallenge(hostID: UUID, _ challenge: HostKeyChallenge) async {
            recorded.append((hostID, challenge))
        }
        func trustHostKey(host: HostConnectionSpec, fingerprint: String) async throws {
            throw ControlConnectError.connectFailed("测试替身不建连接")
        }
    }

    private var container: ModelContainer!
    private var settings: ControlSettings!
    private var coordinator: ForwardingCoordinator!
    private var pool: FakePool!
    private var handler: ControlHandler!
    private var server: ServerProfile!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, ForwardingRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))

        server = ServerProfile()
        server.name = "prod-db"
        server.host = "192.0.2.20"      // TEST-NET-1
        server.username = "deploy"
        container.mainContext.insert(server)
        try container.mainContext.save()

        coordinator = ForwardingCoordinator()
        pool = FakePool()
        settings = ControlSettings(defaults: Self.freshDefaults())
        settings.isEnabled = true
        settings.allowMutations = true
        handler = ControlHandler(
            settings: settings,
            modelContainer: container,
            forwardingCoordinator: coordinator,
            pool: pool,
            registry: TerminalSessionRegistry())
    }

    override func tearDown() async throws {
        ControlHandler.forwardRelayFactoryForTesting = nil
        coordinator?.injectTrafficForTesting(nil)
        handler = nil
        try await super.tearDown()
    }

    private static func freshDefaults() -> UserDefaults {
        let suite = "ControlForwardHandlerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @discardableResult
    private func makeRule(
        name: String,
        kind: ForwardKind = .local,
        listenPort: Int,
        listenHost: String = "127.0.0.1",
        serverID: UUID? = nil,
        sortOrder: Int = 0
    ) throws -> ForwardingRule {
        let rule = ForwardingRule(
            serverID: serverID ?? server.id,
            name: name,
            kind: kind,
            listenHost: listenHost,
            listenPort: listenPort,
            destHost: kind == .dynamic ? nil : "10.0.0.1",
            destPort: kind == .dynamic ? 0 : 5432,
            destLabel: nil,
            autostart: false,
            sortOrder: sortOrder)
        container.mainContext.insert(rule)
        try container.mainContext.save()
        return rule
    }

    // MARK: - 规则解析（纯函数四级）

    /// 规则解析复用 `HostResolver`（原先那份 `ControlForwardRuleResolver` 是它的复制品，
    /// 且已经漂移）。这里断言的是 `HostResolver` 的语义。
    func testRuleResolverLevels() {
        let a = HostResolver.Candidate(id: UUID(), name: "pg-tunnel")
        let b = HostResolver.Candidate(id: UUID(), name: "Redis-Tunnel")
        let pool = [a, b]

        XCTAssertEqual(HostResolver.resolve(a.id.uuidString, in: pool),
                       .matched(a.id), "UUID 直达")
        XCTAssertEqual(HostResolver.resolve("pg-tunnel", in: pool),
                       .matched(a.id), "精确")
        XCTAssertEqual(HostResolver.resolve("redis-tunnel", in: pool),
                       .matched(b.id), "忽略大小写")
        XCTAssertEqual(HostResolver.resolve("pg", in: pool),
                       .matched(a.id), "唯一前缀")
        XCTAssertEqual(HostResolver.resolve("nope", in: pool), .notFound)
    }

    /// `HostResolver` 与被删掉的那份复制品的关键差异：UUID **形状**的 needle 没命中 id 时
    /// 继续往名字匹配上退，而不是直接 `notFound`。
    func testUUIDShapedNeedleFallsBackToNameMatching() {
        let named = HostResolver.Candidate(id: UUID(), name: UUID().uuidString)
        XCTAssertEqual(HostResolver.resolve(named.name, in: [named]),
                       .matched(named.id), "UUID 形状但没命中 id → 退回名字匹配")
        XCTAssertEqual(HostResolver.resolve(UUID().uuidString, in: [named]), .notFound)
    }

    func testRuleResolverAmbiguity() {
        let a = HostResolver.Candidate(id: UUID(), name: "tunnel-a")
        let b = HostResolver.Candidate(id: UUID(), name: "tunnel-b")
        let outcome = HostResolver.resolve("tunnel", in: [a, b])
        XCTAssertEqual(outcome, .ambiguous([a, b]))
    }

    func testAmbiguousRuleNameIsRejected() async throws {
        try makeRule(name: "tunnel-a", listenPort: 15_432)
        try makeRule(name: "tunnel-b", listenPort: 15_433, sortOrder: 1)

        let response = await handler.handle(
            ControlRequest(action: .forwardStop, rule: "tunnel"))

        XCTAssertEqual(response.code, ControlErrorCode.rule_ambiguous.rawValue)
    }

    func testUnknownRuleIsRuleNotFound() async throws {
        let response = await handler.handle(
            ControlRequest(action: .forwardStop, rule: "不存在"))
        XCTAssertEqual(response.code, ControlErrorCode.rule_not_found.rawValue)
    }

    func testMissingRuleArgumentIsInvalidRequest() async throws {
        let response = await handler.handle(ControlRequest(action: .forwardStop))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    /// `--host` 把候选缩到该主机 —— 跨主机同名规则是常态。
    func testRuleLookupIsScopedByHost() async throws {
        let other = ServerProfile()
        other.name = "staging-db"
        other.host = "192.0.2.21"
        container.mainContext.insert(other)
        try container.mainContext.save()

        try makeRule(name: "pg", listenPort: 15_432)
        try makeRule(name: "pg", listenPort: 15_433, serverID: other.id, sortOrder: 1)

        let ambiguous = await handler.handle(
            ControlRequest(action: .forwardStop, rule: "pg"))
        XCTAssertEqual(ambiguous.code, ControlErrorCode.rule_ambiguous.rawValue)

        let scoped = await handler.handle(
            ControlRequest(action: .forwardStop, host: "staging-db", rule: "pg"))
        XCTAssertTrue(scoped.ok, scoped.message)
        XCTAssertEqual(scoped.rules?.first?.listenPort, 15_433)
    }

    // MARK: - forward-list

    func testListAssemblesStatusIssueAndTraffic() async throws {
        let active = try makeRule(name: "pg", listenPort: 15_432)
        let broken = try makeRule(name: "socks", kind: .dynamic,
                                  listenPort: 11_080, sortOrder: 1)

        coordinator.setStatusForTesting(.active, for: active.id)
        coordinator.setStatusForTesting(
            .error(ForwardingError(kind: .unreachable, message: "socks：目标地址无法连接")),
            for: broken.id)
        coordinator.injectTrafficForTesting([active.id: TunnelBytes(up: 11, down: 22)])

        let response = await handler.handle(ControlRequest(action: .forwardList))

        XCTAssertTrue(response.ok, response.message)
        let rules = try XCTUnwrap(response.rules)
        XCTAssertEqual(rules.count, 2)

        let first = rules[0]
        XCTAssertEqual(first.name, "pg")
        XCTAssertEqual(first.serverName, "prod-db")
        XCTAssertEqual(first.serverID, server.id.uuidString)
        XCTAssertEqual(first.kind, "local")
        XCTAssertEqual(first.status, "active")
        XCTAssertEqual(first.destHost, "10.0.0.1")
        XCTAssertEqual(first.destPort, 5432)
        XCTAssertEqual(first.bytesOut, 11, "上行 = 本地→远端")
        XCTAssertEqual(first.bytesIn, 22, "下行 = 远端→本地")
        XCTAssertNil(first.issue)

        let second = rules[1]
        XCTAssertEqual(second.kind, "dynamic")
        XCTAssertEqual(second.status, "error")
        XCTAssertEqual(second.issue, "socks：目标地址无法连接")
        XCTAssertNil(second.destHost, "dynamic 无固定目标")
        XCTAssertNil(second.bytesIn)
    }

    func testListFiltersByHost() async throws {
        let other = ServerProfile()
        other.name = "staging-db"
        other.host = "192.0.2.21"
        container.mainContext.insert(other)
        try container.mainContext.save()

        try makeRule(name: "pg", listenPort: 15_432)
        try makeRule(name: "pg-staging", listenPort: 15_433,
                     serverID: other.id, sortOrder: 1)

        let response = await handler.handle(
            ControlRequest(action: .forwardList, host: "staging-db"))

        XCTAssertEqual(response.rules?.count, 1)
        XCTAssertEqual(response.rules?.first?.name, "pg-staging")
    }

    func testListIsReadableWithMutationsDisabled() async throws {
        settings.allowMutations = false
        try makeRule(name: "pg", listenPort: 15_432)

        let response = await handler.handle(ControlRequest(action: .forwardList))
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.rules?.count, 1)
    }

    func testStartAndStopNeedMutations() async throws {
        settings.allowMutations = false
        try makeRule(name: "pg", listenPort: 15_432)

        for action in [ControlAction.forwardStart, .forwardStop] {
            let response = await handler.handle(
                ControlRequest(action: action, rule: "pg"))
            XCTAssertEqual(response.code, ControlErrorCode.mutations_disabled.rawValue,
                           action.rawValue)
        }
    }

    // MARK: - forward-stop

    func testStopIsIdempotentWhenRuleIsNotRunning() async throws {
        try makeRule(name: "pg", listenPort: 15_432)

        let response = await handler.handle(
            ControlRequest(action: .forwardStop, rule: "pg"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.rules?.first?.status, "inactive")
        XCTAssertTrue(response.message.contains("本来就没在运行"))
    }

    func testStopTurnsRunningRuleInactive() async throws {
        let rule = try makeRule(name: "pg", listenPort: 15_432)
        coordinator.setStatusForTesting(.active, for: rule.id)

        let response = await handler.handle(
            ControlRequest(action: .forwardStop, rule: "pg"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(coordinator.status(rule.id), .inactive)
        XCTAssertEqual(response.rules?.first?.status, "inactive")
    }

    // MARK: - forward-start

    func testStartIsIdempotentWhenAlreadyActive() async throws {
        let rule = try makeRule(name: "pg", listenPort: 15_432)
        coordinator.setStatusForTesting(.active, for: rule.id)

        let response = await handler.handle(
            ControlRequest(action: .forwardStart, rule: "pg"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.rules?.first?.status, "active")
        XCTAssertTrue(response.message.contains("已在运行"))
    }

    /// 端口预检：真绑一个本地端口，再让规则去监听它 —— 必须在建连之前就回 `port_in_use`。
    func testStartRejectsPortAlreadyBoundByAnotherProcess() async throws {
        let listener = try LocalPortHolder()
        defer { listener.close() }

        try makeRule(name: "pg", listenPort: listener.port)

        let response = await handler.handle(
            ControlRequest(action: .forwardStart, rule: "pg"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.port_in_use.rawValue)
        let ruleID = try XCTUnwrap(currentRuleID(named: "pg"))
        XCTAssertEqual(coordinator.status(ruleID), .inactive,
                       "预检拦下时不该已经把规则推进 starting")
    }

    /// 同一个真绑端口，`-R` 规则的监听口开在远端 —— 本机探测不该误报。
    func testRemoteForwardSkipsLocalPortProbe() async throws {
        let listener = try LocalPortHolder()
        defer { listener.close() }

        try makeRule(name: "rev", kind: .remote, listenPort: listener.port)

        let response = await handler.handle(
            ControlRequest(action: .forwardStart, rule: "rev"))

        XCTAssertNotEqual(response.code, ControlErrorCode.port_in_use.rawValue,
                          "-R 的监听口在远端，不该被本机探测判成占用")
    }

    func testStartRejectsPortHeldByAnotherRunningRule() async throws {
        let running = try makeRule(name: "pg", listenPort: 15_432)
        coordinator.setStatusForTesting(.active, for: running.id)
        try makeRule(name: "pg-dup", listenPort: 15_432, sortOrder: 1)

        let response = await handler.handle(
            ControlRequest(action: .forwardStart, rule: "pg-dup"))

        XCTAssertEqual(response.code, ControlErrorCode.port_in_use.rawValue)
        XCTAssertTrue(response.message.contains("pg"), response.message)
    }

    /// 未在跑的同端口规则不算冲突（否则一条停掉的规则会永远挡着另一条）。
    func testStartIgnoresInactiveRuleOnSamePort() async throws {
        try makeRule(name: "pg", listenPort: 15_999)
        try makeRule(name: "pg-dup", listenPort: 15_999, sortOrder: 1)

        let response = await handler.handle(
            ControlRequest(action: .forwardStart, rule: "pg-dup"))

        XCTAssertNotEqual(response.code, ControlErrorCode.port_in_use.rawValue,
                          response.message)
    }

    func testStartFailsWhenServerProfileIsGone() async throws {
        try makeRule(name: "orphan", listenPort: 15_555, serverID: UUID())

        let response = await handler.handle(
            ControlRequest(action: .forwardStart, rule: "orphan"))

        XCTAssertEqual(response.code, ControlErrorCode.host_not_found.rawValue)
    }

    /// 回归：`forward-start` 的挑战落在它自己的临时 relay 上（转发不经连接池），
    /// 必须补记进池 —— 否则 `trust --fingerprint` 找不到可核对的挑战，
    /// 技能文档教的「拿指纹 → trust → 重试」在转发这条路上就断了。
    func testStartRecordsHostKeyChallengeIntoPool() async throws {
        try makeRule(name: "pg", listenPort: 15_432)
        let challenge = HostKeyChallenge(
            host: "192.0.2.20", port: 22, kind: .unknown,
            newFingerprint: "SHA256:abc", oldFingerprint: nil)
        // 挑战是异步落到 relay 上的；换一个预置好挑战的 relay，把时间窗去掉。
        ControlHandler.forwardRelayFactoryForTesting = {
            let relay = HostKeyChallengeRelay()
            relay.pendingChallenge = challenge
            return relay
        }

        let response = await handler.handle(
            ControlRequest(action: .forwardStart, rule: "pg"))

        XCTAssertEqual(response.code, ControlErrorCode.host_key_unknown.rawValue,
                       response.message)
        XCTAssertEqual(response.hostKey?.fingerprint, "SHA256:abc")

        let recorded = await pool.recorded
        XCTAssertEqual(recorded.count, 1, "挑战必须补记进连接池")
        XCTAssertEqual(recorded.first?.0, server.id)
        XCTAssertEqual(recorded.first?.1.newFingerprint, "SHA256:abc")
        let paired = await pool.lastHostKeyChallenge(hostID: server.id)
        XCTAssertEqual(paired?.newFingerprint, "SHA256:abc",
                       "trust --fingerprint 要能从池里配上对")
    }

    /// 回归：`stop` / `teardown` 会把状态写成 `.inactive`。并发 stop 后 `waitForStart`
    /// 必须**立刻**收工回 `forward_failed`，而不是把 `.inactive` 当「仍在启动」空转到超时。
    func testWaitForStartEndsImmediatelyWhenRuleGoesInactive() async throws {
        let deps = try XCTUnwrap(handler.dependencies)
        let ruleID = UUID()
        coordinator.setStatusForTesting(.starting, for: ruleID)

        let flip = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            self.coordinator.setStatusForTesting(.inactive, for: ruleID)
        }
        let started = Date()
        let outcome = await handler.waitForStart(
            ruleID: ruleID, relay: HostKeyChallengeRelay(), deps)
        _ = await flip.value

        guard case .stopped = outcome else {
            return XCTFail("`.inactive` 应立刻收工，实得 \(outcome)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "不该空转到 sshConnectTimeout")
    }

    /// 回归：规则冲突的 `occupant` 是**规则名**。用户把规则起名叫知名端口的服务名
    /// （"AirPlay"）时，真冲突曾被当成「只是个知名端口提醒」吞掉。
    func testRuleNamedAfterWellKnownServiceStillConflicts() async throws {
        let running = try makeRule(name: "AirPlay", listenPort: 5_000)
        coordinator.setStatusForTesting(.active, for: running.id)
        try makeRule(name: "dup", listenPort: 5_000, sortOrder: 1)

        let response = await handler.handle(
            ControlRequest(action: .forwardStart, rule: "dup"))

        XCTAssertEqual(response.code, ControlErrorCode.port_in_use.rawValue,
                       response.message)
        XCTAssertTrue(response.message.contains("规则「AirPlay」"), response.message)
    }

    /// 反面：没有任何在跑的同侧规则时，知名端口本身只是警告 —— 不该被 CLI 当成占用拦下。
    func testWellKnownPortAloneIsNotRejected() async throws {
        // 本机真跑着 cupsd 时第二道预检（真实 bind）会合法地判占用 —— 那不是本例要测的。
        try XCTSkipIf(ControlLocalPortProbe.isBusy(host: "127.0.0.1", port: 631),
                      "本机 631 被真实进程占着，跳过")
        try makeRule(name: "cups", listenPort: 631)

        let response = await handler.handle(
            ControlRequest(action: .forwardStart, rule: "cups"))

        XCTAssertNotEqual(response.code, ControlErrorCode.port_in_use.rawValue,
                          "知名端口只是提醒，交给真实 bind 探测判：\(response.message)")
    }

    // MARK: - 端口探测本身

    func testLocalPortProbeSeesBoundPort() throws {
        let listener = try LocalPortHolder()
        XCTAssertTrue(ControlLocalPortProbe.isBusy(host: "127.0.0.1", port: listener.port))
        listener.close()
        XCTAssertFalse(ControlLocalPortProbe.isBusy(host: "127.0.0.1", port: listener.port))
    }

    func testLocalPortProbeIgnoresNonIPv4Literals() {
        XCTAssertFalse(ControlLocalPortProbe.isBusy(host: "example.invalid", port: 80))
        XCTAssertFalse(ControlLocalPortProbe.isBusy(host: "127.0.0.1", port: 0))
    }

    // MARK: - 工具

    private func currentRuleID(named name: String) -> UUID? {
        let rules = ForwardingRuleStore(context: container.mainContext).allRules()
        return rules.first { $0.name == name }?.id
    }
}

/// 占住一个本机端口的最小 helper：绑 + listen 一个 127.0.0.1 上的随机端口。
/// 只用 POSIX socket，不引入 NIO —— 这里要的只是「有人占着」这个事实。
private final class LocalPortHolder {
    let port: Int
    private var fd: Int32
    private var closed = false

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw NSError(domain: "LocalPortHolder", code: 1)
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                    // 让内核挑一个空闲端口
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 1) == 0 else {
            Darwin.close(socketFD)
            throw NSError(domain: "LocalPortHolder", code: 2)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard got == 0 else {
            Darwin.close(socketFD)
            throw NSError(domain: "LocalPortHolder", code: 3)
        }
        fd = socketFD
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    deinit { if !closed { Darwin.close(fd) } }
}
