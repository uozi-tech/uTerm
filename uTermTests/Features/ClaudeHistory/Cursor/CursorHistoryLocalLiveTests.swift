import Foundation
import XCTest
@testable import uTerm

/// Cursor 命令行的历史会话在**这台 Mac 的真实记录**（`~/.cursor/chats`）上跑一遍，读法同 App：沙盒里的测试宿主经包内
/// 不带沙盒的辅助程序 `uTermShellAgent.xpc` 读文件。
///
/// 会读你自己的记录，所以**默认跳过**，开关是 `UTERM_CURSOR_HISTORY_LOCAL=1`（xcodebuild 传环境变量要加 `TEST_RUNNER_`
/// 前缀）。**只读**：不往 `~/.cursor` 写任何东西（不跑 `sqlite3`，`-shm` 也不碰），对话内容只在内存里。
/// 日志里只有条数、字节数和耗时，没有标题、路径或对话内容。
@MainActor
final class CursorHistoryLocalLiveTests: XCTestCase {
    private var client: LocalShellAgentClient!
    private var provider: RemoteMacFileProvider!

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["UTERM_CURSOR_HISTORY_LOCAL"] == "1" else {
            throw XCTSkip("没设 UTERM_CURSOR_HISTORY_LOCAL=1，跳过读本机真实记录的测试")
        }
        client = LocalShellAgentClient()
        provider = RemoteMacFileProvider.localShellAgent(client: client)
    }

    override func tearDown() async throws {
        client?.invalidate()
        try await super.tearDown()
    }

    func testReadsRealRecords() async throws {
        let source = CursorHistorySource(provider: provider)
        var started = ContinuousClock.now
        let projects = try await source.projects()
        let listProjects = ContinuousClock.now - started
        guard !projects.isEmpty else { throw XCTSkip("这台 Mac 上没有 ~/.cursor/chats") }
        let resolved = projects.filter { $0.directory != nil }.count

        started = ContinuousClock.now
        let all = await source.allSessions(in: projects)
        let listSessions = ContinuousClock.now - started
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(all.map(\.modifiedAt), all.map(\.modifiedAt).sorted(by: >), "新的在前")
        let sizes = all.map(\.size).sorted()
        print("""
            [cursor-history-local] projects=\(projects.count) withDirectory=\(resolved) in \(listProjects), \
            sessions=\(all.count) in \(listSessions), bytes(main+wal) min=\(sizes.first ?? 0) \
            median=\(sizes[sizes.count / 2]) max=\(sizes.last ?? 0) total=\(sizes.reduce(0, +))
            """)

        var listed = 0, hidden = 0, titled = 0, resumable = 0, failed = 0
        started = ContinuousClock.now
        for file in all {
            guard let info = try? await source.metadata(for: file) else {
                failed += 1
                continue
            }
            guard info.isListed else {
                hidden += 1
                continue
            }
            listed += 1
            if info.title != nil { titled += 1 }
            if let directory = info.resumeDirectory {
                // 继续会话的目录 MD5 必须正好是项目目录名（`--resume` 按它找会话）。
                XCTAssertEqual(CursorWorkspace.hash(of: directory), file.project.id)
                XCTAssertNotNil(source.resumeCommand(sessionID: file.sessionID, directory: directory))
                resumable += 1
            }
        }
        let readMetadata = ContinuousClock.now - started
        XCTAssertEqual(failed, 0, "有 \(failed) 份记录读不出元数据")
        print("""
            [cursor-history-local] metadata for \(all.count) in \(readMetadata): listed=\(listed) hidden=\(hidden) \
            titled=\(titled) resumable=\(resumable)
            """)

        // 每份都整份打开一遍：读得出来、ID 不重复、结果都挂得上调用；记下耗时。
        for file in all {
            let pager = source.transcript(for: file)
            let opened = ContinuousClock.now
            var items: [AgentTranscriptItem] = []
            var reachedStart = false
            var pages = 0
            while !reachedStart, pages < 200 {
                let page = try await pager.loadPrevious()
                if pages == 0 {
                    let first = ContinuousClock.now - opened
                    XCTAssertLessThan(first, .seconds(5), "\(file.size) 字节的记录第一页用了 \(first)")
                    print("[cursor-history-local] transcript bytes=\(file.size) first page in \(first)")
                }
                items = page.items + items
                reachedStart = page.reachedStart
                pages += 1
            }
            XCTAssertEqual(Set(items.map(\.id)).count, items.count, "条目的 ID 有重复")
            let assembled = AgentTranscriptAssembler.attachResults(items)
            let orphans = assembled.filter { if case .toolResult = $0.kind { return true } else { return false } }.count
            XCTAssertEqual(orphans, 0, "有工具结果没挂到调用下面")
            let calls = items.filter { if case .toolCall = $0.kind { return true } else { return false } }.count
            // 跟随：没变就什么都不读。
            let polled = ContinuousClock.now
            let growth = try await pager.loadNewer()
            print("""
                [cursor-history-local] transcript bytes=\(file.size) pages=\(pages) items=\(items.count) calls=\(calls) \
                total \(ContinuousClock.now - opened), poll \(growth == .unchanged ? "unchanged" : "changed") in \
                \(ContinuousClock.now - polled)
                """)
        }
    }
}
