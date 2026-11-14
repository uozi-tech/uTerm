import XCTest
@testable import uTerm

/// 被控端授权问谁：远控进程答了以它为准；不认得这条命令（旧版本）立刻退回本进程；没回话就隔一会儿再问，
/// 问不到再退回本进程。
@MainActor
final class RemoteHostPermissionSourceTests: XCTestCase {
    private let local = RemoteHostAgentPermissions(screenCapture: true, postEvents: true)

    func test_no_agent_uses_local_permissions() async {
        let result = await RemoteHostPermissionSource.current(agent: nil, local: { self.local })
        XCTAssertEqual(result, local)
    }

    func test_old_agent_that_rejects_the_command_falls_back_to_local_without_retrying() async {
        let agent = FakeAgentLink { _ in RemoteHostAgentCommandReply(ok: false, error: "远控进程不认得这个操作") }
        let result = await RemoteHostPermissionSource.current(agent: agent, retryDelay: .seconds(5), attempts: 3,
                                                              local: { self.local })
        XCTAssertEqual(result, local)
        XCTAssertEqual(agent.sent.count, 1, "旧版本回了话，不必再问")
    }

    func test_unreachable_agent_is_retried_then_answers() async {
        let answer = RemoteHostAgentPermissions(screenCapture: true, postEvents: false)
        var calls = 0
        let agent = FakeAgentLink { _ in
            calls += 1
            guard calls >= 3 else { return nil }
            return RemoteHostAgentCommandReply(data: RemoteHostAgentJSON.encode(answer))
        }
        let result = await RemoteHostPermissionSource.current(agent: agent, retryDelay: .milliseconds(10), attempts: 5,
                                                              local: { self.local })
        XCTAssertEqual(result, answer, "远控进程刚重启：等它连上再答，不拿 App 的结果顶替")
        XCTAssertEqual(calls, 3)
    }

    func test_agent_that_never_replies_times_out_and_falls_back_to_local() async {
        let agent = FakeAgentLink { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        let started = ContinuousClock.now
        let result = await RemoteHostPermissionSource.current(agent: agent, retryDelay: .milliseconds(10), attempts: 2,
                                                              replyTimeout: .milliseconds(100), local: { self.local })
        XCTAssertEqual(result, local)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "连接断掉时不等 send 自己的 130 秒")
    }

    func test_request_falls_back_to_local_when_agent_cannot_take_it() async {
        var localRequests = 0
        let agent = FakeAgentLink { _ in RemoteHostAgentCommandReply(ok: false, error: "远控进程不认得这个操作") }
        await RemoteHostPermissionSource.requestPostEvents(agent: agent, local: { localRequests += 1 })
        XCTAssertEqual(localRequests, 1)
        XCTAssertEqual(agent.sent.count, 1)
    }
}

@MainActor
private final class FakeAgentLink: RemoteHostAgentLink {
    private let respond: @MainActor (RemoteHostAgentCommand) async -> RemoteHostAgentCommandReply?
    private(set) var sent: [RemoteHostAgentCommand] = []

    init(_ respond: @escaping @MainActor (RemoteHostAgentCommand) async -> RemoteHostAgentCommandReply?) {
        self.respond = respond
    }

    func post(_ command: RemoteHostAgentCommand) {
        sent.append(command)
    }

    func send(_ command: RemoteHostAgentCommand) async -> RemoteHostAgentCommandReply? {
        sent.append(command)
        return await respond(command)
    }
}
