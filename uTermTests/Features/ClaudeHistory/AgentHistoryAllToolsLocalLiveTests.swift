import XCTest
@testable import uTerm

/// 四种工具合起来，在**这台 Mac 的真实记录**上跑一遍，走 App 里建数据源的同一个入口（`AgentHistorySources.make`），
/// 读法同 App：经包内不带沙盒的辅助程序 `uTermShellAgent.xpc`。
///
/// 会读你自己的记录，所以**默认跳过**，开关是 `UTERM_AGENT_HISTORY_LOCAL=1`（xcodebuild 传环境变量要加
/// `TEST_RUNNER_` 前缀）。**只读**；日志与失败信息里只有条数和耗时，没有标题、路径或对话内容。
@MainActor
final class AgentHistoryAllToolsLocalLiveTests: XCTestCase {
    private var client: LocalShellAgentClient!
    private var provider: RemoteMacFileProvider!

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["UTERM_AGENT_HISTORY_LOCAL"] == "1" else {
            throw XCTSkip("没设 UTERM_AGENT_HISTORY_LOCAL=1，跳过读本机真实记录的测试")
        }
        client = LocalShellAgentClient()
        provider = RemoteMacFileProvider.localShellAgent(client: client)
    }

    override func tearDown() async throws {
        client?.invalidate()
        try await super.tearDown()
    }

    /// 每种工具：列得出项目和会话，项目带着自己的 `tool`；合起来之后按项目分组，数一数跨工具并到一起的组。
    func testListsEveryToolAndGroupsByProject() async throws {
        let source = AgentHistorySources.make(tools: AgentHistoryTool.allCases, provider: provider)
        guard let composite = source as? AgentHistoryCompositeSource else {
            return XCTFail("四种工具都要了，应该是合成的数据源")
        }
        var started = ContinuousClock.now
        let projects = try await composite.projects()
        let listProjects = ContinuousClock.now - started
        let failures = await composite.failures
        XCTAssertTrue(failures.isEmpty, "有 \(failures.count) 种工具的记录列不出来")

        started = ContinuousClock.now
        let files = await composite.allSessions(in: projects)
        let listSessions = ContinuousClock.now - started
        XCTAssertEqual(files.map(\.modifiedAt), files.map(\.modifiedAt).sorted(by: >), "合起来之后仍然新的在前")

        started = ContinuousClock.now
        var metadata: [String: AgentHistorySessionMetadata] = [:]
        var unreadable = 0
        for file in files {
            if let info = try? await composite.metadata(for: file) { metadata[file.path] = info } else { unreadable += 1 }
        }
        let readMetadata = ContinuousClock.now - started
        let listed = files.filter { metadata[$0.path]?.isListed == true }

        for tool in AgentHistoryTool.allCases {
            let ofTool = listed.filter { $0.tool == tool }
            let withDirectory = projects.filter { $0.tool == tool && $0.directory != nil }.count
            let resumable = ofTool.filter { file in
                guard let directory = metadata[file.path]?.resumeDirectory else { return false }
                return composite.source(for: tool)?.resumeCommand(sessionID: file.sessionID, directory: directory) != nil
            }.count
            print("""
                [agent-history-local] \(tool.rawValue): projects=\(projects.filter { $0.tool == tool }.count) \
                (withDirectory=\(withDirectory)) sessions=\(files.filter { $0.tool == tool }.count) listed=\(ofTool.count) \
                resumable=\(resumable)
                """)
        }
        let groups = AgentHistoryListing.projectGroups(listed, metadata: metadata)
        let mixed = groups.filter { Set($0.files.map(\.tool)).count > 1 }.count
        let noDirectory = groups.filter { if case .noDirectory = $0.kind { return true } else { return false } }
        print("""
            [agent-history-local] projects in \(listProjects), sessions in \(listSessions), metadata in \(readMetadata) \
            (unreadable=\(unreadable)); groups=\(groups.count) mixedTools=\(mixed) \
            noDirectoryGroups=\(noDirectory.count) (sessions=\(noDirectory.map(\.files.count).reduce(0, +)))
            """)
    }
}
