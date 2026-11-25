import AgentKit
import SwiftData
import XCTest
@testable import uTerm

/// 两端共用的 `ParallelRunModel`（macOS 参数：`.safety` 审批 + macOS 终端描述），
/// 经执行器缝注入假会话，不连真机器。
@MainActor
final class ParallelRunModelTests: XCTestCase {

    // MARK: - 「信任并重试」不吞日志

    /// 首轮还没收尾（别的台还在跑）时对某台点「信任并重试」，整次运行照常在最终收尾时记一条日志。
    /// 改前 macOS 一律关掉落库，这次运行就从执行日志里消失了。
    func testTrustAndRetryBeforeFirstRoundFinishesStillRecordsRun() async throws {
        let (store, container) = try makeStore()
        let cmd = store.create(name: "uptime", serverIDs: [], command: "uptime", aiAssisted: false)
        let a = host("a"), b = host("b")
        let gate = FakeGate()
        let challenge = HostKeyChallenge(host: "a.example", port: 22, kind: .unknown,
                                         newFingerprint: "SHA256:test", oldFingerprint: nil)
        let executor = FakeExecutor { profile, pin in
            if profile == a.id {
                return pin?.matches(challenge) == true ? FakeSession() : FakeSession(hostKey: challenge)
            }
            return FakeSession(gate: gate)
        }
        let model = makeModel(commandID: cmd.id, command: "uptime", intent: "", aiAssisted: false,
                              targets: [a, b], doctor: nil, store: store, container: container,
                              executor: executor)
        model.start()
        try await waitUntil { model.states[0].hostKeyUntrusted }
        XCTAssertFalse(model.allDone, "b 还在跑")

        model.trustAndRetry(serverID: a.id)
        try await waitUntil { model.states[0].tone == .ok }
        await gate.open()
        try await waitUntil { model.allDone }

        let runs = store.runs(for: cmd.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.results.map(\.ok), [true, true])
    }

    // MARK: - 连接方式变弱了

    /// 卡片上的问题是「连接方式变弱了」：结论写的是它、按钮是「仍然连接并重试」；点了之后重试只放行这一问
    /// （主机密钥要是也变了，还会再出一张主机密钥的卡片），同意也不在点的时候记——连上之后按 USSHKit 的结果记。
    func testWeakAlgorithmsRetryPinsOnlyThatAskAndRecordsNothingYet() async throws {
        let (store, container) = try makeStore()
        let cmd = store.create(name: "uptime", serverIDs: [], command: "uptime", aiAssisted: false)
        let a = host("a")
        let challenge = HostKeyChallenge(host: "a.example", port: 22, kind: .weakAlgorithms,
                                         newFingerprint: "", oldFingerprint: nil)
        var calls: [HostKeyApprovalPin?] = []
        let executor = FakeExecutor { _, pin in
            calls.append(pin)
            return calls.count == 1 ? FakeSession(hostKey: challenge) : FakeSession()
        }
        let model = makeModel(commandID: cmd.id, command: "uptime", intent: "", aiAssisted: false,
                              targets: [a], doctor: nil, store: store, container: container,
                              executor: executor)
        model.start()
        try await waitUntil { model.states[0].hostKeyUntrusted }
        XCTAssertTrue(model.states[0].weakAlgorithmsDeclined)
        XCTAssertEqual(model.states[0].hostKeyRetryTitle, String(localized: "仍然连接并重试"))
        XCTAssertEqual(model.states[0].summary, ParallelRunCopy.weakAlgorithms(challenge))

        model.trustAndRetry(serverID: a.id)
        try await waitUntil { model.states[0].tone == .ok }
        XCTAssertEqual(calls, [nil, HostKeyApprovalPin(challenge)], "重试只放行卡片上那一问")
        let pin = HostKeyApprovalPin(challenge)
        XCTAssertFalse(pin.matches(HostKeyChallenge(host: "a.example", port: 22, kind: .unknown,
                                                    newFingerprint: "SHA256:x", oldFingerprint: nil)),
                       "连接方式那一问的放行管不到主机密钥")
    }

    /// 钉住的是用户看到的那一问：跳板机后面的目标、换了一把钥匙、变成「密钥已变化」、同一台的别的端口都不放行。
    func testPinMatchesOnlyTheExactChallenge() {
        let seen = HostKeyChallenge(host: "bastion", port: 22, kind: .unknown,
                                    newFingerprint: "SHA256:bastion", oldFingerprint: nil)
        let pin = HostKeyApprovalPin(seen)
        XCTAssertTrue(pin.matches(HostKeyChallenge(host: "bastion", port: 22, kind: .unknown,
                                                   newFingerprint: "SHA256:bastion", oldFingerprint: nil)),
                      "同一问（重连时是新的挑战对象）放行")
        let others = [
            HostKeyChallenge(host: "target", port: 22, kind: .unknown, newFingerprint: "SHA256:target", oldFingerprint: nil),
            HostKeyChallenge(host: "bastion", port: 22, kind: .unknown, newFingerprint: "SHA256:other", oldFingerprint: nil),
            HostKeyChallenge(host: "bastion", port: 22, kind: .mismatch, newFingerprint: "SHA256:bastion",
                             oldFingerprint: "SHA256:old"),
            HostKeyChallenge(host: "bastion", port: 2222, kind: .unknown, newFingerprint: "SHA256:bastion", oldFingerprint: nil),
            HostKeyChallenge(host: "bastion", port: 22, kind: .weakAlgorithms, newFingerprint: "", oldFingerprint: nil),
        ]
        for other in others { XCTAssertFalse(pin.matches(other), "\(other)") }
    }

    /// 「信任并重试」重连时跳板机后面的目标也是未知密钥：不被顺手放过去，另出一张目标的卡片。
    func testTrustAndRetryDoesNotApproveTheNextHopsKey() async throws {
        let (store, container) = try makeStore()
        let cmd = store.create(name: "uptime", serverIDs: [], command: "uptime", aiAssisted: false)
        let a = host("a")
        let bastion = HostKeyChallenge(host: "bastion", port: 22, kind: .unknown,
                                       newFingerprint: "SHA256:bastion", oldFingerprint: nil)
        let target = HostKeyChallenge(host: "a.example", port: 22, kind: .unknown,
                                      newFingerprint: "SHA256:target", oldFingerprint: nil)
        let executor = FakeExecutor { _, pin in
            // 真执行器里审批闭包只放行钉住的那一问：跳板机放行了，目标那一问照常拒绝、记下。
            guard let pin, pin.matches(bastion) else { return FakeSession(hostKey: bastion) }
            return pin.matches(target) ? FakeSession() : FakeSession(hostKey: target)
        }
        let model = makeModel(commandID: cmd.id, command: "uptime", intent: "", aiAssisted: false,
                              targets: [a], doctor: nil, store: store, container: container,
                              executor: executor)
        model.start()
        try await waitUntil { model.states[0].hostKeyUntrusted }
        model.trustAndRetry(serverID: a.id)
        try await waitUntil {
            if case .hostKeyUntrusted(let shown)? = model.states[0].failure { return shown.host == "a.example" }
            return false
        }
    }

    // MARK: - 纯意图命令的退出码

    /// 没有等效命令的 AI 命令：日志里的退出码取 Agent 最后一条真实命令的（改前 macOS 恒为「—」）。
    func testIntentOnlyAICommandRecordsLastAgentExitCode() async throws {
        let (store, container) = try makeStore()
        let cmd = store.create(name: "看系统版本", serverIDs: [], command: "",
                               intent: "看一下系统版本", aiAssisted: true)
        let llm = MockLLMClient(scripts: [
            [Self.call("cat /etc/os-release")],
            [.text(#"{"status":"ok","summary":"Ubuntu 24.04。"}"#)],
        ])
        var doctor = ParallelAIDoctor(client: llm, model: "test",
                                      baseURL: URL(string: "https://example.invalid")!, apiKey: "k")
        doctor.retryDelay = { _ in .zero }
        let executor = FakeExecutor { _, _ in
            FakeSession(result: CommandResult(output: "NAME=Ubuntu", exitCode: 0))
        }
        let model = makeModel(commandID: cmd.id, command: "", intent: cmd.intent, aiAssisted: true,
                              targets: [host("a")], doctor: doctor, store: store, container: container,
                              executor: executor)
        model.start()
        try await waitUntil { !store.runs(for: cmd.id).isEmpty }

        let result = try XCTUnwrap(store.runs(for: cmd.id).first?.results.first)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - 装配

    private func makeStore() throws -> (QuickCommandStore, ModelContainer) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: QuickCommand.self, QuickCommandRun.self,
                                           configurations: config)
        return (QuickCommandStore(context: container.mainContext), container)
    }

    private func host(_ name: String) -> ServerProfile {
        let p = ServerProfile()
        p.name = name; p.host = "\(name).example"; p.username = "root"; p.port = 22
        return p
    }

    private func makeModel(commandID: UUID, command: String, intent: String, aiAssisted: Bool,
                           targets: [ServerProfile], doctor: ParallelAIDoctor?,
                           store: QuickCommandStore, container: ModelContainer,
                           executor: FakeExecutor) -> ParallelRunModel {
        ParallelRunModel(commandID: commandID, commandName: "测试", command: command, intent: intent,
                         aiAssisted: aiAssisted, targets: targets, doctor: doctor,
                         approval: .safety(.readAuto), hostLabel: "macOS 原生 SSH 终端",
                         store: store, container: container, executor: executor)
    }

    private func waitUntil(timeout: Duration = .seconds(4),
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("等待超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func call(_ command: String) -> LLMEvent {
        let args = (try? JSONSerialization.data(withJSONObject: ["command": command]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .toolCall(LLMToolCall(id: UUID().uuidString, name: "run_command", argumentsJSON: args))
    }
}

// MARK: - 假执行器

private struct FakeExecutor: ParallelCommandExecuting {
    let make: @MainActor (UUID, HostKeyApprovalPin?) -> FakeSession

    init(_ make: @escaping @MainActor (UUID, HostKeyApprovalPin?) -> FakeSession) { self.make = make }

    func makeSession(for profile: ServerProfile, approving pin: HostKeyApprovalPin?) async -> ParallelExecutionSession {
        make(profile.id, pin)
    }
}

/// 一台的假会话：可以拿着 host-key 质询拒连、可以卡在闸门上等放行，其余照脚本返回结果。
private nonisolated final class FakeSession: ParallelExecutionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var challenge: HostKeyChallenge?
    private let gate: FakeGate?
    private let result: CommandResult

    init(hostKey: HostKeyChallenge? = nil, gate: FakeGate? = nil,
         result: CommandResult = CommandResult(output: "ok", exitCode: 0)) {
        self.challenge = hostKey
        self.gate = gate
        self.result = result
    }

    var setupErrorText: String? { nil }

    func run(_ command: String,
             onLines: @escaping @Sendable ([ParallelTermLine]) -> Void) async throws -> CommandResult {
        if lock.withLock({ challenge != nil }) { throw URLError(.secureConnectionFailed) }
        if let gate { await gate.wait() }
        return result
    }

    func takeHostKeyChallenge() -> HostKeyChallenge? {
        lock.withLock {
            defer { challenge = nil }
            return challenge
        }
    }

    func close() async {}
}

private actor FakeGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
