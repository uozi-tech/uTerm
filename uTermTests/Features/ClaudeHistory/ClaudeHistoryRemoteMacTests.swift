import SwiftData
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 配对的 Mac 上的历史会话：真的 `RemoteMacClient` 经本机回环的加密链路连进程内的被控端，`ClaudeHistorySource` 经
/// `RemoteMacFileProvider` 读一棵手写的假记录目录（在测试宿主自己的临时目录里，主目录由 `home` 注入）。
/// 被控端不起辅助程序（XPC 要真机），文件请求直接交给同一份 `RemoteFileService`，同 `RemoteMacFilesEndToEndTests`。
@MainActor
final class ClaudeHistoryRemoteMacTests: XCTestCase {
    private var home = ""
    private let directory = "/home/user/projects/demo"
    private var projectsRoot: String { home + "/.claude/projects" }
    private var projectPath: String { projectsRoot + "/" + ClaudeProjectPath.encode(directory) }

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        home = base.appendingPathComponent("claude-history-mac-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: home)
        try await super.tearDown()
    }

    // MARK: - 夹具

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// 被控端数着收到了几次文件请求：没有 `files` 能力时一次都不该发。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func pairedClient(features: [String] = RemoteConstants.localFeatures,
                              requests: Counter = Counter()) async throws -> (RemoteHostServer, RemoteMacClient) {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false, localFeatures: features)
        server.fileAccess = RemoteFileAccess(refusal: { _ in nil }, perform: { payload in
            requests.bump()
            return RemoteFileService.handle(payload)
        })
        server.start()
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        _ = await waitUntil { !server.pairingRequests.isEmpty }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        return (server, client)
    }

    private func sessionID(_ index: Int) -> String {
        String(format: "%08x-0000-4000-8000-%012x", index, index)
    }

    /// 写一份会话记录，修改时间越往后越新（`index` 大的新）。
    private func writeSession(_ index: Int, lines: [String]) throws {
        let path = projectPath + "/" + sessionID(index) + ".jsonl"
        try ClaudeFixture.file(lines).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)],
                                              ofItemAtPath: path)
    }

    private func settle(_ history: AgentHistoryModel) async {
        _ = await waitUntil(10) { !history.isListing && (history.visibleFiles.count >= 24 || !history.hasMore) }
    }

    // MARK: - 用例

    func testListsTitlesAndPagesOverTheRemoteLink() async throws {
        // 60 份命令行会话 + 2 份桌面版（不列）：一批 24 行，连提前读的那十几份算上，第一批也读不到底。
        for index in 0..<60 {
            try writeSession(index, lines: [ClaudeFixture.userText("问题 \(index)", cwd: directory),
                                            ClaudeFixture.assistant(ClaudeFixture.textBlock("回答 \(index)"), cwd: directory),
                                            ClaudeFixture.aiTitle("会话 \(index)")])
        }
        for index in 60..<62 {
            try writeSession(index, lines: [ClaudeFixture.userText("桌面", entrypoint: "claude-desktop", cwd: directory),
                                            ClaudeFixture.aiTitle("桌面版 \(index)")])
        }
        let (server, client) = try await pairedClient()
        defer { server.stop() }

        let source = ClaudeHistorySource(provider: RemoteMacFileProvider(client: client), home: home)
        let history = AgentHistoryModel(source: source, preferredDirectory: nil)
        await history.start()
        await settle(history)

        XCTAssertEqual(history.phase, .ready)
        XCTAssertEqual(history.scope, .all, "配对的 Mac 不知道终端当前目录，列全部项目")
        XCTAssertEqual(history.files.count, 62)
        let firstPage = history.visibleFiles
        XCTAssertGreaterThanOrEqual(firstPage.count, 24)
        XCTAssertLessThan(firstPage.count, 60, "第一批不读到底")
        XCTAssertTrue(history.hasMore)
        XCTAssertEqual(history.metadata[firstPage[0].path]?.title, "会话 59", "新的在前，桌面版的不列")
        XCTAssertEqual(AgentHistoryText.sessionTitle(firstPage[0], metadata: history.metadata[firstPage[0].path]), "会话 59")

        // 滚到底几次，读完为止（上一批没读完时催它不起作用，所以每次等它停下来再催）。
        for _ in 0..<5 where history.hasMore {
            let before = history.visibleFiles.count
            history.loadMore()
            _ = await waitUntil(10) { !history.hasMore || history.visibleFiles.count >= before + 24 }
        }
        XCTAssertFalse(history.hasMore)
        XCTAssertEqual(history.visibleFiles.map { history.metadata[$0.path]?.title },
                       (0..<60).reversed().map { "会话 \($0)" })
        XCTAssertEqual(history.hiddenCount, 2)
        XCTAssertEqual(history.resumeCommand(for: history.visibleFiles[0])?.directory, directory)

        // 对话：从末尾往前读，标题行不算消息。
        history.select(history.visibleFiles[0])
        let transcript = try XCTUnwrap(history.transcript)
        _ = await waitUntil(10) { transcript.reachedStart }
        XCTAssertEqual(transcript.items.map(\.plainText), ["问题 59", "回答 59"])
        XCTAssertEqual(client.state, .connected)
    }

    func testTranscriptPagesBackwardsThroughALargeRemoteFile() async throws {
        // 一份很长的会话，一页读不完。
        var lines: [String] = []
        for index in 0..<400 {
            lines.append(ClaudeFixture.userText("第 \(index) 句 " + String(repeating: "长", count: 200), uuid: "u-\(index)",
                                                cwd: directory))
        }
        lines.append(ClaudeFixture.aiTitle("很长的会话"))
        try writeSession(1, lines: lines)
        let (server, client) = try await pairedClient()
        defer { server.stop() }

        let history = AgentHistoryModel(source: ClaudeHistorySource(provider: RemoteMacFileProvider(client: client), home: home),
                                        preferredDirectory: nil)
        await history.start()
        await settle(history)
        let file = try XCTUnwrap(history.visibleFiles.first)
        XCTAssertEqual(history.metadata[file.path]?.title, "很长的会话")
        history.select(file)
        let transcript = try XCTUnwrap(history.transcript)
        _ = await waitUntil(10) { !transcript.items.isEmpty && !transcript.isLoading }
        XCTAssertFalse(transcript.reachedStart, "第一页读不到开头")
        XCTAssertTrue(transcript.items.last?.plainText.hasPrefix("第 399 句") == true)
        var pages = 1
        while !transcript.reachedStart, pages < 50 {
            await transcript.loadEarlier()
            pages += 1
        }
        XCTAssertTrue(transcript.reachedStart)
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(transcript.items.count, 400)
        XCTAssertTrue(transcript.items.first?.plainText.hasPrefix("第 0 句") == true)
    }

    /// 共享的连接状态机接配对的 Mac：连上、看能力、建通道、列项目。
    func testConnectionOpensAPairedMac() async throws {
        try writeSession(3, lines: [ClaudeFixture.userText("你好", cwd: directory), ClaudeFixture.aiTitle("打招呼")])
        let (server, client) = try await pairedClient()
        defer { server.stop() }

        let connection = AgentHistoryConnection(preferredDirectory: nil, home: home,
                                                connect: AgentHistoryAccess.pairedMac(client))
        await connection.open()
        let history = try XCTUnwrap(connection.history, "\(String(describing: connection.failureMessage))")
        await settle(history)
        XCTAssertEqual(history.visibleFiles.map { history.metadata[$0.path]?.title }, ["打招呼"])
        connection.close()
    }

    /// 那台 Mac 的 uTerm 太旧、握手里没有 `files`：一个文件请求都不发（老版本收到不认识的消息会断开整条连接），
    /// 直接说清楚是版本太旧；连接照常连着。
    func testMacWithoutFilesCapabilityIsNotAskedForFiles() async throws {
        let requests = Counter()
        let (server, client) = try await pairedClient(
            features: RemoteConstants.localFeatures.filter { $0 != RemoteFeature.files }, requests: requests)
        defer { server.stop() }
        XCTAssertFalse(client.supportsFiles)

        let connection = AgentHistoryConnection(preferredDirectory: nil, home: home,
                                                connect: AgentHistoryAccess.pairedMac(client))
        await connection.open()
        XCTAssertNil(connection.history)
        XCTAssertEqual(connection.failureMessage, AgentHistoryAccess.unsupportedMacMessage)
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(client.state, .connected)
    }
}
