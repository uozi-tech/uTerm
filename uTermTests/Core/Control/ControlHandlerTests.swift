import SwiftData
import XCTest
@testable import uTerm

/// `ControlHandler` 的门禁矩阵与执行面。连接池整个是注入的假货，所以这些用例
/// 不碰网络、不碰钥匙串（`HostConnectionSpec.keychainOverride` 顶掉真实钥匙串）、
/// 也不碰用户的库（内存 `ModelContainer`）。
@MainActor
final class ControlHandlerTests: XCTestCase {

    // MARK: - 夹具

    /// 注入的假连接池：脚本化 exec 输出 / 建连错误 / 主机密钥质询，并记下释放调用。
    actor FakePool: ControlConnectionPooling {
        private var exec: @Sendable (String) async throws -> String = { _ in "" }
        private var globalError: ControlConnectError?
        private var errorsByHost: [UUID: ControlConnectError] = [:]
        private var challenges: [UUID: HostKeyChallenge] = [:]
        private var held: [UUID] = []
        private var trustError: ControlConnectError?
        private(set) var executorRequests: [(id: UUID, maxLines: Int, maxBytes: Int)] = []
        private(set) var trustCalls: [(id: UUID, fingerprint: String)] = []
        private(set) var disconnected: [UUID] = []
        private(set) var disconnectAllCalls = 0

        func setExec(_ handler: @escaping @Sendable (String) async throws -> String) { exec = handler }
        func setError(_ error: ControlConnectError?) { globalError = error }
        func setError(_ error: ControlConnectError, for hostID: UUID) { errorsByHost[hostID] = error }
        func setChallenge(_ challenge: HostKeyChallenge?, for hostID: UUID) { challenges[hostID] = challenge }
        func setHeld(_ ids: [UUID]) { held = ids }
        func setTrustError(_ error: ControlConnectError?) { trustError = error }

        func executor(
            for host: HostConnectionSpec,
            maxLines: Int,
            maxBytes: Int
        ) async throws -> SSHCommandExecutor {
            executorRequests.append((host.id, maxLines, maxBytes))
            if let error = errorsByHost[host.id] { throw error }
            if let globalError { throw globalError }
            let handler = exec
            return SSHCommandExecutor(maxLines: maxLines, maxBytes: maxBytes, exec: handler)
        }

        func borrowSFTP(for host: HostConnectionSpec) async throws -> any SFTPProviding {
            throw ControlConnectError.connectFailed("测试不建 SFTP")
        }

        func returnSFTP(_ session: any SFTPProviding, for hostID: UUID) async {}

        func disconnect(hostID: UUID) async { disconnected.append(hostID) }
        func disconnectAll() async { disconnectAllCalls += 1 }
        func heldHostIDs() async -> [UUID] { held }
        func lastHostKeyChallenge(hostID: UUID) async -> HostKeyChallenge? { challenges[hostID] }
        func recordChallenge(hostID: UUID, _ challenge: HostKeyChallenge) async {
            challenges[hostID] = challenge
        }

        func trustHostKey(host: HostConnectionSpec, fingerprint: String) async throws {
            if let trustError { throw trustError }
            trustCalls.append((host.id, fingerprint))
        }
    }

    /// 顶掉真实钥匙串：测试宿主的钥匙串里当然没有这些主机的密码。
    private struct StubKeychain: KeychainReading {
        func load(profileID: UUID, kind: SecretKind) throws -> String? {
            kind == .password ? "pw" : nil
        }
    }

    private var container: ModelContainer!
    private var settings: ControlSettings!
    private var pool: FakePool!
    private var handler: ControlHandler!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, QuickCommand.self, QuickCommandRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "control-handler-tests-\(UUID().uuidString)"))
        settings = ControlSettings(defaults: defaults)
        settings.isEnabled = true
        settings.allowMutations = true
        pool = FakePool()
        handler = ControlHandler(
            settings: settings,
            modelContainer: container,
            forwardingCoordinator: ForwardingCoordinator(),
            pool: pool,
            registry: TerminalSessionRegistry()
        )
        HostConnectionSpec.keychainOverride = StubKeychain()
    }

    override func tearDown() async throws {
        HostConnectionSpec.keychainOverride = nil
        try await super.tearDown()
    }

    @discardableResult
    private func makeProfile(
        name: String,
        host: String = "10.0.0.1",
        sortOrder: Int = 0,
        sftpOnly: Bool = false
    ) -> ServerProfile {
        let profile = ServerProfile()
        profile.name = name
        profile.host = host
        profile.port = 22
        profile.username = "root"
        profile.authMethod = .password
        profile.sortOrder = sortOrder
        profile.sftpOnly = sftpOnly
        container.mainContext.insert(profile)
        try? container.mainContext.save()
        return profile
    }

    /// 造一条「被哨兵包过」的 exec 输出（`SSHCommandExecutor` 靠它拿真实退出码）。
    private nonisolated static func wire(_ text: String, exit: Int) -> String {
        "\(text)\n\(SSHCommandExecutor.sentinel):\(exit)\n"
    }

    // MARK: - 门禁矩阵

    func testPingWorksEvenWithEverythingOff() async {
        settings.isEnabled = false
        settings.allowMutations = false
        let response = await handler.handle(ControlRequest(action: .ping))
        XCTAssertTrue(response.ok, "ping 必须永远可用，否则客户端连「开关关着」都问不出来")
        XCTAssertEqual(response.app?.controlEnabled, false)
        XCTAssertEqual(response.app?.mutationsEnabled, false)
    }

    func testMainSwitchGatesEverythingButPing() async {
        settings.isEnabled = false
        for action in [ControlAction.hosts, .run, .trust, .disconnect] {
            let response = await handler.handle(ControlRequest(action: action, host: "x"))
            XCTAssertEqual(response.code, ControlErrorCode.control_disabled.rawValue,
                           "\(action.rawValue) 应被主开关拦下")
        }
    }

    func testMutationSwitchGatesRunAndTrustOnly() async {
        makeProfile(name: "web")
        settings.allowMutations = false

        let run = await handler.handle(ControlRequest(action: .run, host: "web", command: "uptime"))
        XCTAssertEqual(run.code, ControlErrorCode.mutations_disabled.rawValue)
        let trust = await handler.handle(
            ControlRequest(action: .trust, host: "web", fingerprint: "SHA256:x")
        )
        XCTAssertEqual(trust.code, ControlErrorCode.mutations_disabled.rawValue)

        // 只读动作不受第二个开关影响。
        let hosts = await handler.handle(ControlRequest(action: .hosts))
        XCTAssertTrue(hosts.ok, hosts.message)
        let disconnect = await handler.handle(ControlRequest(action: .disconnect, host: "web"))
        XCTAssertTrue(disconnect.ok, disconnect.message)
    }

    func testSFTPOnlyHostRejectsRun() async {
        makeProfile(name: "files", sftpOnly: true)
        let response = await handler.handle(
            ControlRequest(action: .run, host: "files", command: "uptime")
        )
        XCTAssertEqual(response.code, ControlErrorCode.host_sftp_only.rawValue)
        let requests = await pool.executorRequests
        XCTAssertTrue(requests.isEmpty, "被主机级硬规则拦下就不该去建连")
    }

    // MARK: - hosts / 解析

    func testHostsListsProfilesInSortOrderWithPoolState() async {
        let web = makeProfile(name: "web", sortOrder: 1)
        makeProfile(name: "db", host: "10.0.0.2", sortOrder: 0)
        await pool.setHeld([web.id])

        let response = await handler.handle(ControlRequest(action: .hosts))
        let hosts = try? XCTUnwrap(response.hosts)
        XCTAssertEqual(hosts?.map(\.name), ["db", "web"])
        XCTAssertEqual(hosts?.first(where: { $0.name == "web" })?.cliConnected, true)
        XCTAssertEqual(hosts?.first(where: { $0.name == "db" })?.cliConnected, false)
        XCTAssertEqual(hosts?.first?.activeForwards, 0)
        XCTAssertEqual(hosts?.first(where: { $0.name == "web" })?.id, web.id.uuidString)
    }

    func testUnknownHostIsReported() async {
        makeProfile(name: "web")
        let response = await handler.handle(ControlRequest(action: .run, host: "nope", command: "x"))
        XCTAssertEqual(response.code, ControlErrorCode.host_not_found.rawValue)
    }

    func testAmbiguousHostReturnsCandidatesWithUUIDs() async {
        let a = makeProfile(name: "web", host: "10.0.0.1")
        let b = makeProfile(name: "web", host: "10.0.0.2")
        await pool.setHeld([a.id])
        let response = await handler.handle(ControlRequest(action: .run, host: "web", command: "x"))
        XCTAssertEqual(response.code, ControlErrorCode.host_ambiguous.rawValue)
        XCTAssertEqual(Set(response.hosts?.map(\.id) ?? []), [a.id.uuidString, b.id.uuidString])
        // 候选的 cliConnected 由 `handle` 的收口 await 连接池补上（同步解析路径问不到）。
        XCTAssertEqual(response.hosts?.first(where: { $0.id == a.id.uuidString })?.cliConnected, true)
        XCTAssertEqual(response.hosts?.first(where: { $0.id == b.id.uuidString })?.cliConnected, false)
    }

    // MARK: - run

    func testRunReturnsOutputAndExitCode() async {
        makeProfile(name: "web")
        await pool.setExec { command in
            XCTAssertTrue(command.contains("uptime"), "包装后的命令要含原命令：\(command)")
            return Self.wire("up 3 days", exit: 0)
        }
        let response = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "uptime")
        )
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.result?.output, "up 3 days")
        XCTAssertEqual(response.result?.exitCode, 0)
        XCTAssertEqual(response.result?.timedOut, false)
        XCTAssertEqual(response.result?.truncated, false)
    }

    func testRunSurfacesNonZeroExitWithoutFailingTheRequest() async {
        makeProfile(name: "web")
        await pool.setExec { _ in Self.wire("no such file", exit: 2) }
        let response = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "cat /nope")
        )
        XCTAssertTrue(response.ok, "非零退出是命令的结果，不是 IPC 的失败")
        XCTAssertEqual(response.result?.exitCode, 2)
    }

    func testRunJoinsArgvSafelyWhenOnlyArgsGiven() async {
        makeProfile(name: "web")
        let seen = SeenCommand()
        await pool.setExec { command in
            seen.store(command)
            return Self.wire("ok", exit: 0)
        }
        _ = await handler.handle(
            ControlRequest(action: .run, host: "web", args: ["echo", "hello world"])
        )
        XCTAssertTrue(seen.value?.contains("echo 'hello world'") == true,
                      "带空格的 argv 必须被引起来：\(seen.value ?? "")")
    }

    func testRunPassesRequestLimitsToThePool() async {
        makeProfile(name: "web")
        await pool.setExec { _ in Self.wire("ok", exit: 0) }
        _ = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "x",
                           maxLines: 5, maxBytes: 99_999_999)
        )
        let request = await pool.executorRequests.first
        XCTAssertEqual(request?.maxLines, 5)
        XCTAssertEqual(request?.maxBytes, ControlProtocol.maxOutputBytes, "maxBytes 要封顶")
    }

    func testRunTimesOutAndSaysTheCommandMayStillBeRunning() async {
        makeProfile(name: "web")
        await pool.setExec { _ in
            try? await Task.sleep(for: .seconds(120))
            return Self.wire("too late", exit: 0)
        }
        let response = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "tail -f /var/log/syslog",
                           timeoutSeconds: 1)
        )
        XCTAssertEqual(response.code, ControlErrorCode.command_timeout.rawValue)
        XCTAssertTrue(response.message.contains("仍在远端运行"), response.message)
        XCTAssertEqual(response.results?.first?.timedOut, true)
    }

    func testRunMapsUnknownHostKeyWithFingerprint() async {
        makeProfile(name: "web")
        await pool.setError(.hostKeyUnknown(fingerprint: "SHA256:abc", algorithm: "ssh-ed25519"))
        let response = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "uptime")
        )
        XCTAssertEqual(response.code, ControlErrorCode.host_key_unknown.rawValue)
        XCTAssertEqual(response.hostKey?.fingerprint, "SHA256:abc")
        XCTAssertEqual(response.hostKey?.algorithm, "ssh-ed25519")
        XCTAssertEqual(response.hostKey?.status, "unknown")
    }

    func testRunMapsChangedHostKey() async {
        makeProfile(name: "web")
        await pool.setError(.hostKeyChanged(fingerprint: "SHA256:new", algorithm: ""))
        let response = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "uptime")
        )
        XCTAssertEqual(response.code, ControlErrorCode.host_key_changed.rawValue)
        XCTAssertEqual(response.hostKey?.status, "changed")
        XCTAssertNil(response.hostKey?.algorithm, "算法拿不到时给 nil，不要空串")
    }

    func testRunMapsAuthAndConnectFailures() async {
        makeProfile(name: "web")
        await pool.setError(.authFailed("密码不对"))
        var response = await handler.handle(ControlRequest(action: .run, host: "web", command: "x"))
        XCTAssertEqual(response.code, ControlErrorCode.auth_failed.rawValue)

        await pool.setError(.connectFailed("连接超时"))
        response = await handler.handle(ControlRequest(action: .run, host: "web", command: "x"))
        XCTAssertEqual(response.code, ControlErrorCode.connect_failed.rawValue)
        XCTAssertTrue(response.message.contains("连接超时"), response.message)
    }

    /// 执行阶段抛错（连接是好的、命令跑挂了）不能冒充 `connect_failed`。
    ///
    /// 回归：真机上 `run -c 'exit 3'` 顶层退掉整个 shell，Citadel 对非零退出抛错，
    /// 这里原来一律映射成 `connect_failed` + `FriendlyError` 洗过的
    /// 「操作未能完成，请稍后重试」，3 ms 返回 —— 对模型完全指错方向。
    func testExecPhaseFailureIsOperationFailedWithTheRawError() async {
        makeProfile(name: "web")
        struct RemoteExecFailure: Error { let detail = "非零退出：3" }
        await pool.setExec { _ in throw RemoteExecFailure() }

        let response = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "exit 3"))

        XCTAssertEqual(response.code, ControlErrorCode.operation_failed.rawValue)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message.contains("RemoteExecFailure"),
                      "message 要给原话，实得：\(response.message)")
        XCTAssertFalse(response.message.contains("请稍后重试"),
                       "CLI 的 message 不该被 FriendlyError 洗过")
        XCTAssertEqual(response.results?.first?.errorCode,
                       ControlErrorCode.operation_failed.rawValue)
    }

    /// 执行阶段真的抛出 `ControlConnectError`（复用连接时才暴露的密钥变更之类）
    /// 仍走连接失败那条路，指纹要带出来。
    func testExecPhaseConnectErrorStillReportsHostKey() async {
        makeProfile(name: "web")
        await pool.setExec { _ in
            throw ControlConnectError.hostKeyChanged(fingerprint: "SHA256:zzz", algorithm: "")
        }

        let response = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "uptime"))

        XCTAssertEqual(response.code, ControlErrorCode.host_key_changed.rawValue)
        XCTAssertEqual(response.hostKey?.fingerprint, "SHA256:zzz")
    }

    /// `run-many` 的逐条 `errorCode` 同理 —— 一台执行失败不该报成连不上。
    func testRunManyMarksExecPhaseFailurePerHost() async {
        makeProfile(name: "web")
        makeProfile(name: "db")
        struct RemoteExecFailure: Error {}
        await pool.setExec { _ in throw RemoteExecFailure() }

        let response = await handler.handle(
            ControlRequest(action: .runMany, hosts: ["web", "db"], command: "exit 3"))

        XCTAssertEqual(response.code, ControlErrorCode.run_failed.rawValue)
        XCTAssertEqual(response.results?.count, 2)
        for result in response.results ?? [] {
            XCTAssertEqual(result.errorCode, ControlErrorCode.operation_failed.rawValue)
            XCTAssertTrue(result.errorMessage?.contains("RemoteExecFailure") == true,
                          result.errorMessage ?? "")
        }
    }

    /// 顶层 `exit N` 现在被子 shell 兜住：哨兵照常带出退出码，`ok: true`。
    func testTopLevelExitStillReportsExitCodeThroughTheSentinel() async {
        makeProfile(name: "web")
        await pool.setExec { command in
            // 真实 shell 的行为：子 shell 里 exit 3 只退子 shell，哨兵照常打印。
            XCTAssertTrue(command.hasPrefix("( exit 3\n)"), command)
            return Self.wire("", exit: 3)
        }

        let response = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "exit 3"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.result?.exitCode, 3)
    }

    func testRunRequiresACommand() async {
        makeProfile(name: "web")
        let response = await handler.handle(ControlRequest(action: .run, host: "web"))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    // MARK: - run-many

    func testRunManyKeepsRequestOrderAndIsolatesFailures() async {
        makeProfile(name: "a", host: "10.0.0.1", sortOrder: 0)
        let b = makeProfile(name: "b", host: "10.0.0.2", sortOrder: 1)
        makeProfile(name: "c", host: "10.0.0.3", sortOrder: 2)
        await pool.setExec { _ in Self.wire("ok", exit: 0) }
        await pool.setError(.connectFailed("b 连不上"), for: b.id)

        let response = await handler.handle(
            ControlRequest(action: .runMany, hosts: ["c", "b", "a"], command: "uptime")
        )
        // 有一台失败 → 整体不再是 ok（但另外两台照跑，结果都在）。
        XCTAssertEqual(response.code, ControlErrorCode.run_partial_failure.rawValue)
        let results = try? XCTUnwrap(response.results)
        XCTAssertEqual(results?.map(\.host), ["c", "b", "a"], "结果必须按请求顺序回")
        XCTAssertEqual(results?[1].errorCode, ControlErrorCode.connect_failed.rawValue)
        XCTAssertNil(results?[0].errorCode)
        XCTAssertEqual(results?[2].exitCode, 0, "一台失败不该影响其它台")
    }

    /// 同一台主机被指了两次（重复 `-H`、名字 + UUID、大小写变体）只跑一遍。
    ///
    /// 回归的是一次崩溃：`quick-run` 用 `Dictionary(uniqueKeysWithValues:)` 建端点
    /// 字典，重复的 hostID 直接 trap 掉整个 app。
    func testRunManyMergesDuplicateHosts() async {
        let web = makeProfile(name: "web")
        await pool.setExec { _ in Self.wire("ok", exit: 0) }

        let response = await handler.handle(
            ControlRequest(action: .runMany,
                           hosts: ["web", "web", "WEB", web.id.uuidString],
                           command: "uptime")
        )
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.results?.count, 1, "四种写法指的是同一台，只该有一条结果")
        let requests = await pool.executorRequests
        XCTAssertEqual(requests.count, 1, "同一台主机不该被跑两遍")
        XCTAssertTrue(response.message.contains("合并"), response.message)
    }

    func testQuickRunMergesDuplicateHostOverridesWithoutCrashing() async {
        let web = makeProfile(name: "web")
        let store = QuickCommandStore(context: container.mainContext)
        let command = store.create(name: "磁盘", serverIDs: [web.id], command: "df -h",
                                   aiAssisted: false)
        await pool.setExec { _ in Self.wire("ok", exit: 0) }

        let response = await handler.handle(
            ControlRequest(action: .quickRun,
                           hosts: ["web", web.id.uuidString, "WEB"],
                           name: "磁盘")
        )
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.results?.count, 1)
        XCTAssertEqual(store.runs(for: command.id).first?.results.count, 1,
                       "运行日志里也该是去重后的一台")
    }

    // MARK: - run-many 的成败语义

    /// 全部失败**不能**再回 `ok: true` —— `utermctl run-many … && 下一步` 会被骗。
    func testRunManyReportsRunFailedWhenNoHostSucceeds() async {
        makeProfile(name: "a", host: "10.0.0.1", sortOrder: 0)
        makeProfile(name: "b", host: "10.0.0.2", sortOrder: 1)
        await pool.setError(.connectFailed("都连不上"))

        let response = await handler.handle(
            ControlRequest(action: .runMany, hosts: ["a", "b"], command: "uptime")
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.run_failed.rawValue)
        XCTAssertEqual(response.results?.count, 2, "逐台结果照旧要在")
    }

    func testRunManyReportsPartialFailure() async {
        makeProfile(name: "a", host: "10.0.0.1", sortOrder: 0)
        let b = makeProfile(name: "b", host: "10.0.0.2", sortOrder: 1)
        await pool.setExec { _ in Self.wire("ok", exit: 0) }
        await pool.setError(.connectFailed("b 连不上"), for: b.id)

        let response = await handler.handle(
            ControlRequest(action: .runMany, hosts: ["a", "b"], command: "uptime")
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.run_partial_failure.rawValue)
        XCTAssertEqual(response.results?.map(\.host), ["a", "b"])
        XCTAssertNil(response.results?[0].errorCode)
    }

    /// 命令自己返回非 0 也算这台失败（`run-many` 的语义是「都成了吗」）。
    func testRunManyCountsNonZeroExitAsAFailedHost() async {
        makeProfile(name: "a", host: "10.0.0.1", sortOrder: 0)
        makeProfile(name: "b", host: "10.0.0.2", sortOrder: 1)
        await pool.setExec { _ in Self.wire("boom", exit: 3) }

        let response = await handler.handle(
            ControlRequest(action: .runMany, hosts: ["a", "b"], command: "false")
        )
        XCTAssertEqual(response.code, ControlErrorCode.run_failed.rawValue)
        XCTAssertEqual(response.results?.first?.exitCode, 3)
    }

    /// 未知主机密钥：顶层 `hostKey` 要有（模型读顶层拿指纹），逐条也要有
    /// （多台首连时只有逐条那份说得清是哪几台）。
    func testRunManySurfacesHostKeyAtTopLevelAndPerResult() async {
        let a = makeProfile(name: "a", host: "10.0.0.1", sortOrder: 0)
        let b = makeProfile(name: "b", host: "10.0.0.2", sortOrder: 1)
        await pool.setError(.hostKeyUnknown(fingerprint: "SHA256:aaa", algorithm: "ssh-ed25519"),
                            for: a.id)
        await pool.setError(.hostKeyUnknown(fingerprint: "SHA256:bbb", algorithm: "ssh-rsa"),
                            for: b.id)

        let response = await handler.handle(
            ControlRequest(action: .runMany, hosts: ["a", "b"], command: "uptime")
        )
        XCTAssertEqual(response.code, ControlErrorCode.run_failed.rawValue)
        XCTAssertEqual(response.hostKey?.fingerprint, "SHA256:aaa", "顶层取第一台")
        XCTAssertEqual(response.hostKey?.status, "unknown")
        XCTAssertEqual(response.results?.map { $0.hostKey?.fingerprint },
                       ["SHA256:aaa", "SHA256:bbb"], "逐条各带各的指纹")
        XCTAssertEqual(response.results?.last?.hostKey?.algorithm, "ssh-rsa")
    }

    /// 单机 `run` 的非零退出仍然是 `ok: true` —— 那是命令的结果，不是 IPC 的失败。
    func testQuickRunReportsRunFailedWhenEveryHostFails() async {
        let web = makeProfile(name: "web")
        let store = QuickCommandStore(context: container.mainContext)
        store.create(name: "磁盘", serverIDs: [web.id], command: "df -h", aiAssisted: false)
        await pool.setError(.authFailed("密码不对"))

        let response = await handler.handle(ControlRequest(action: .quickRun, name: "磁盘"))
        XCTAssertEqual(response.code, ControlErrorCode.run_failed.rawValue)
        XCTAssertEqual(response.results?.first?.errorCode, ControlErrorCode.auth_failed.rawValue)
    }

    /// 输出被裁剪时 `truncated` 由执行器直接带出（不再靠嗅探末尾文案）。
    func testRunReportsTruncationFromTheExecutor() async {
        makeProfile(name: "web")
        await pool.setExec { _ in
            Self.wire((1...50).map { "line \($0)" }.joined(separator: "\n"), exit: 0)
        }
        let response = await handler.handle(
            ControlRequest(action: .run, host: "web", command: "seq 50", maxLines: 5)
        )
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.result?.truncated, true)
        XCTAssertTrue(
            response.result?.output.hasSuffix(SSHCommandExecutor.truncationMarker) == true,
            response.result?.output ?? ""
        )
    }

    func testRunManyRejectsTheWholeBatchWhenAHostNameIsWrong() async {
        makeProfile(name: "a")
        await pool.setExec { _ in Self.wire("ok", exit: 0) }
        let response = await handler.handle(
            ControlRequest(action: .runMany, hosts: ["a", "typo"], command: "rm -rf /tmp/x")
        )
        XCTAssertEqual(response.code, ControlErrorCode.host_not_found.rawValue)
        let requests = await pool.executorRequests
        XCTAssertTrue(requests.isEmpty, "名字打错时一台都不许跑")
    }

    // MARK: - quick-commands / quick-run

    func testQuickCommandsListsWithServerNames() async {
        let web = makeProfile(name: "web")
        let store = QuickCommandStore(context: container.mainContext)
        store.create(name: "重启 nginx", serverIDs: [web.id],
                     command: "systemctl restart nginx", aiAssisted: false)

        let response = await handler.handle(ControlRequest(action: .quickCommands))
        XCTAssertEqual(response.quickCommands?.count, 1)
        XCTAssertEqual(response.quickCommands?.first?.serverNames, ["web"])
        XCTAssertEqual(response.quickCommands?.first?.command, "systemctl restart nginx")
    }

    func testQuickRunExecutesBoundHostsAndWritesTheRunLog() async {
        let web = makeProfile(name: "web")
        let store = QuickCommandStore(context: container.mainContext)
        let command = store.create(name: "磁盘", serverIDs: [web.id], command: "df -h", aiAssisted: false)
        await pool.setExec { _ in Self.wire("/dev/disk1", exit: 0) }

        let response = await handler.handle(ControlRequest(action: .quickRun, name: "磁盘"))
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.results?.count, 1)
        XCTAssertEqual(response.results?.first?.exitCode, 0)

        let runs = store.runs(for: command.id)
        XCTAssertEqual(runs.count, 1, "CLI 跑的这次要出现在欢迎页的 30 天日志里")
        XCTAssertEqual(runs.first?.results.count, 1)
        XCTAssertEqual(runs.first?.results.first?.serverName, "web")
        XCTAssertEqual(runs.first?.results.first?.endpoint, "root@10.0.0.1:22")
        XCTAssertEqual(runs.first?.results.first?.ok, true)
        XCTAssertEqual(command.runCount, 1, "runCount 只该 +1（recordRun 已经记了，别再 recordInvocation）")
        XCTAssertNotNil(command.lastRunAt)
    }

    func testQuickRunHostOverrideWins() async {
        let web = makeProfile(name: "web", host: "10.0.0.1")
        makeProfile(name: "db", host: "10.0.0.2")
        let store = QuickCommandStore(context: container.mainContext)
        store.create(name: "磁盘", serverIDs: [web.id], command: "df -h", aiAssisted: false)
        await pool.setExec { _ in Self.wire("ok", exit: 0) }

        let response = await handler.handle(
            ControlRequest(action: .quickRun, hosts: ["db"], name: "磁盘")
        )
        XCTAssertEqual(response.results?.map(\.host), ["db"])
    }

    func testQuickRunRejectsAIOnlyCommands() async {
        let web = makeProfile(name: "web")
        let store = QuickCommandStore(context: container.mainContext)
        store.create(name: "看看怎么了", serverIDs: [web.id], command: "",
                     intent: "帮我看看磁盘满没满", aiAssisted: true)

        let response = await handler.handle(ControlRequest(action: .quickRun, name: "看看怎么了"))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
        XCTAssertTrue(response.message.contains("AI 介入"), response.message)
    }

    // MARK: - host-key / trust

    func testHostKeyReportsUnknownWhenNothingTrusted() async {
        makeProfile(name: "web")
        let response = await handler.handle(ControlRequest(action: .hostKey, host: "web"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.hostKey?.status, "unknown")
        XCTAssertNil(response.hostKey?.fingerprint)
    }

    func testHostKeyReportsTrustedRecord() async {
        makeProfile(name: "web", host: "10.0.0.1")
        let known = KnownHost()
        known.host = "10.0.0.1"
        known.port = 22
        known.keyTypeRaw = "ssh-ed25519"
        known.fingerprint = "SHA256:abc"
        container.mainContext.insert(known)
        try? container.mainContext.save()

        let response = await handler.handle(ControlRequest(action: .hostKey, host: "web"))
        XCTAssertEqual(response.hostKey?.status, "known")
        XCTAssertEqual(response.hostKey?.fingerprint, "SHA256:abc")
        XCTAssertEqual(response.hostKey?.algorithm, "ssh-ed25519")
        XCTAssertNotNil(response.hostKey?.firstTrustedAt)
    }

    func testTrustNeedsAChallengeFirst() async {
        makeProfile(name: "web")
        let response = await handler.handle(
            ControlRequest(action: .trust, host: "web", fingerprint: "SHA256:abc")
        )
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
        XCTAssertTrue(response.message.contains("run"), response.message)
        let calls = await pool.trustCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testTrustNeedsAFingerprint() async {
        makeProfile(name: "web")
        let response = await handler.handle(ControlRequest(action: .trust, host: "web"))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testTrustRejectsMismatchedFingerprint() async {
        let web = makeProfile(name: "web")
        await pool.setChallenge(
            HostKeyChallenge(host: "10.0.0.1", port: 22, kind: .unknown,
                             newFingerprint: "SHA256:real", oldFingerprint: nil),
            for: web.id
        )
        let response = await handler.handle(
            ControlRequest(action: .trust, host: "web", fingerprint: "SHA256:wrong")
        )
        XCTAssertEqual(response.code, ControlErrorCode.host_key_mismatch.rawValue)
        let calls = await pool.trustCalls
        XCTAssertTrue(calls.isEmpty, "指纹对不上绝不能写信任库")
    }

    /// 密钥**变更**即便 mutation 开着也不给 CLI 覆盖 —— 这是中间人风险的最后一道闸。
    func testTrustRefusesToOverwriteAChangedHostKey() async {
        let web = makeProfile(name: "web")
        await pool.setChallenge(
            HostKeyChallenge(host: "10.0.0.1", port: 22, kind: .mismatch,
                             newFingerprint: "SHA256:new", oldFingerprint: "SHA256:old"),
            for: web.id
        )
        let response = await handler.handle(
            ControlRequest(action: .trust, host: "web", fingerprint: "SHA256:new")
        )
        XCTAssertEqual(response.code, ControlErrorCode.host_key_changed.rawValue)
        let calls = await pool.trustCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testTrustPinsTheMatchingFingerprint() async {
        let web = makeProfile(name: "web")
        await pool.setChallenge(
            HostKeyChallenge(host: "10.0.0.1", port: 22, kind: .unknown,
                             newFingerprint: "SHA256:real", oldFingerprint: nil),
            for: web.id
        )
        let response = await handler.handle(
            ControlRequest(action: .trust, host: "web", fingerprint: " SHA256:real ")
        )
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.hostKey?.status, "known")
        let calls = await pool.trustCalls
        XCTAssertEqual(calls.map(\.fingerprint), ["SHA256:real"])
        XCTAssertEqual(calls.map(\.id), [web.id])
    }

    // MARK: - disconnect

    func testDisconnectReleasesOneHost() async {
        let web = makeProfile(name: "web")
        let response = await handler.handle(ControlRequest(action: .disconnect, host: "web"))
        XCTAssertTrue(response.ok)
        let released = await pool.disconnected
        XCTAssertEqual(released, [web.id])
    }

    func testDisconnectWithoutHostReleasesEverything() async {
        let response = await handler.handle(ControlRequest(action: .disconnect))
        XCTAssertTrue(response.ok)
        let count = await pool.disconnectAllCalls
        XCTAssertEqual(count, 1)
    }

    // MARK: - 未接线的实例

    func testUnattachedHandlerReportsAppNotReady() async {
        let response = await ControlHandler().handle(ControlRequest(action: .hosts))
        XCTAssertEqual(response.code, ControlErrorCode.app_not_ready.rawValue)
    }

    /// exec 闭包在别的隔离域里跑，用锁把它写的东西带回测试线程。
    private final class SeenCommand: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        func store(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            stored = value
        }

        var value: String? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }
}
