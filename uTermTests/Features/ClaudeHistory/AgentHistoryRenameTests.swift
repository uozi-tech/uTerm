import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import uTerm

/// 会话的「重命名」「拷贝会话名」（用户要的：同 Claude Code Desktop）与删掉「接着往下聊」串起来的整个对话。
@MainActor
final class AgentHistoryRenameTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "history-rename-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        defaults?.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func start(_ source: any AgentHistorySource) async -> AgentHistoryModel {
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
        return history
    }

    private func session(_ id: String, title: String, ago: TimeInterval, continuedIn: String? = nil) -> Session {
        Session(id: id, projectID: ClaudeProjectPath.encode("/srv/shop"), resumeDirectory: "/srv/shop", title: title,
                modifiedAt: Date().addingTimeInterval(-ago), continuedIn: continuedIn)
    }

    // MARK: 菜单

    func testMenuOrderMatchesDesktop() {
        typealias Item = AgentHistorySessionMenuItem
        XCTAssertEqual(Item.items(hasRecord: true, canResume: true, canPin: true, isPinned: false, isRunning: false,
                                  canDelete: true, canRename: true),
                       [.resume, .pin(isPinned: false), .rename, .copyTitle, .copySessionID, .delete])
        XCTAssertEqual(Item.items(hasRecord: true, canResume: true, canPin: true, isPinned: true, isRunning: true,
                                  canDelete: true, canRename: true),
                       [.pin(isPinned: true), .rename, .copyTitle, .endSession], "跑着的也能改名、拷贝名字")
        XCTAssertEqual(Item.items(hasRecord: false, canResume: false, canPin: false, isPinned: false, isRunning: true,
                                  canDelete: false, canRename: true), [.endSession], "还没对上记录的新会话只能结束")
    }

    // MARK: 模型

    func testRenameUpdatesTheRowRightAway() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", title: "旧名字", ago: 60)])
        let history = await start(source)
        let file = try XCTUnwrap(history.visibleFiles.first)
        XCTAssertTrue(history.canRename(file))

        try await history.rename(file, to: "  新名字  \n")

        let renames = await source.renames
        XCTAssertEqual(renames, ["a=新名字"], "去掉首尾空白后写回记录")
        XCTAssertEqual(AgentHistoryText.sessionTitle(file, metadata: history.metadata[file.path]), "新名字",
                       "不等重读就换")
        try await history.rename(file, to: "   ")
        let after = await source.renames
        XCTAssertEqual(after.count, 1, "空名字不改")
    }

    func testFailedRenameKeepsTheTitle() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", title: "旧名字", ago: 60)])
        await source.setRenameError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        let history = await start(source)
        let file = try XCTUnwrap(history.visibleFiles.first)
        do {
            try await history.rename(file, to: "新名字")
            XCTFail("改不了要报出来")
        } catch {}
        XCTAssertEqual(history.metadata[file.path]?.title, "旧名字")
    }

    func testToolsWithoutRenameAreNotOffered() async throws {
        let antigravity = AgentHistoryFakeSource(tool: .antigravity, sessions: [
            Session(id: "c", projectID: "/srv/shop", projectDirectory: "/srv/shop", resumeDirectory: "/srv/shop",
                    title: "Antigravity 的会话", modifiedAt: Date()),
        ], supportsRename: false)
        let history = await start(antigravity)
        let file = try XCTUnwrap(history.visibleFiles.first)
        XCTAssertFalse(history.canRename(file))
    }

    func testDeletingAContinuedConversationDeletesEveryPart() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [
            session("p1", title: "同一个对话", ago: 300, continuedIn: "p2"),
            session("p2", title: "同一个对话", ago: 200, continuedIn: "p3"),
            session("p3", title: "同一个对话", ago: 100),
            session("other", title: "别的", ago: 50),
        ])
        let history = await start(source)
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), ["other", "p3"])
        let latest = try XCTUnwrap(history.visibleFiles.first { $0.sessionID == "p3" })

        try await history.delete(latest)

        let deleted = await source.deleted
        XCTAssertEqual(Set(deleted), ["p1", "p2", "p3"], "前面那几段一起删，不然删了这一行之前那段又冒出来")
        XCTAssertEqual(history.visibleFiles.map(\.sessionID), ["other"])
    }

    // MARK: Claude Code 的记录

    /// 追加的那一行要是 Claude Code `/rename` 写的同一种（`custom-title`），列表读得出来；名字里有引号、`!`、`$` 都原样。
    func testClaudeRenameCommandAppendsACustomTitleLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let title = #"它's "新" 名字 $HOME !x \ 反斜杠"#
        for endsWithNewline in [true, false] {
            let path = directory.appendingPathComponent("s\(endsWithNewline).jsonl").path
            var data = ClaudeFixture.file([ClaudeFixture.userText("你好")])
            if !endsWithNewline { data.removeLast() }
            try data.write(to: URL(fileURLWithPath: path))

            let command = ClaudeHistorySource.renameCommand(path: path, sessionID: "s1", title: title)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let written = try Data(contentsOf: URL(fileURLWithPath: path))
            let scan = ClaudeSessionScan.scan(written, dropsLeadingPartial: false, dropsTrailingPartial: false)
            XCTAssertEqual(scan.customTitle, title, "末尾\(endsWithNewline ? "是" : "不是")换行")
            XCTAssertTrue(scan.hasMessageLine, "原来那一行还在，没被盖掉")
            XCTAssertEqual(written.last, 0x0A)
        }
    }

    // MARK: 原地改名（用户要的：右键「重命名…」直接把那一行的名字换成输入框，不弹窗）

    func testInlineRenameEditsOnlyThatRowAndShowsTheNewNameWhileSaving() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", title: "旧名字", ago: 60),
                                                                      session("b", title: "别的", ago: 120)])
        let history = await start(source)
        let a = try XCTUnwrap(history.visibleFiles.first { $0.sessionID == "a" })
        let b = try XCTUnwrap(history.visibleFiles.first { $0.sessionID == "b" })
        let renaming = AgentHistoryRenaming()

        renaming.start(a)
        guard case .editing(let editor) = renaming.state(of: a, in: history) else { return XCTFail("点了重命名的那一行换成输入框") }
        XCTAssertEqual(editor.initial, "旧名字", "输入框里一开始是原来的名字")
        XCTAssertNil(renaming.state(of: b, in: history), "别的行不动")

        editor.commit("  新名字 ")
        XCTAssertEqual(renaming.state(of: a, in: history), .saving("新名字"), "回车后输入框收起，写回的那一会儿就显示新名字")
        for _ in 0..<200 where renaming.state(of: a, in: history) != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(renaming.state(of: a, in: history))
        XCTAssertEqual(AgentHistoryText.sessionTitle(a, metadata: history.metadata[a.path]), "新名字")
        let renames = await source.renames
        XCTAssertEqual(renames, ["a=新名字"])
    }

    func testInlineRenameCancelUnchangedAndEmptyWriteNothing() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", title: "旧名字", ago: 60)])
        let history = await start(source)
        let a = try XCTUnwrap(history.visibleFiles.first)
        let renaming = AgentHistoryRenaming()
        for finish in [{ (e: AgentHistoryTitleEditor) in e.cancel() }, { $0.commit("旧名字") }, { $0.commit("   ") }] {
            renaming.start(a)
            guard case .editing(let editor) = renaming.state(of: a, in: history) else { return XCTFail() }
            finish(editor)
            XCTAssertNil(renaming.state(of: a, in: history), "Esc、名字没改、清空了：输入框收起，什么都不写")
        }
        try await Task.sleep(for: .milliseconds(50))
        let renames = await source.renames
        XCTAssertEqual(renames, [])
    }

    func testInlineRenameFailureShowsTheReasonAndKeepsTheOldName() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", title: "旧名字", ago: 60)])
        await source.setRenameError(AgentHistoryDeleteError.renameUnsupported)
        let history = await start(source)
        let a = try XCTUnwrap(history.visibleFiles.first)
        let renaming = AgentHistoryRenaming()
        renaming.start(a)
        guard case .editing(let editor) = renaming.state(of: a, in: history) else { return XCTFail() }
        editor.commit("新名字")
        for _ in 0..<200 where renaming.failure == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(renaming.failure, "写不回去：提示原因")
        XCTAssertNil(renaming.state(of: a, in: history), "行上回到原来的名字")
        XCTAssertEqual(AgentHistoryText.sessionTitle(a, metadata: history.metadata[a.path]), "旧名字")
    }


    /// 行上真的换成了输入框：里面是原来的名字、已经拿到焦点（右键之后直接打字），回车写回、行上换成新名字。
    func testRowTurnsIntoAFocusedFieldInPlace() async throws {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [session("a", title: "旧名字", ago: 60)])
        let history = await start(source)
        let a = try XCTUnwrap(history.visibleFiles.first)
        let renaming = AgentHistoryRenaming()
        let host = NSHostingView(rootView: AgentHistorySessionRow(history: history, file: a, metadata: history.metadata[a.path],
                                                                  isSelected: false, renaming: renaming)
            .frame(width: 300))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        let window = ProbeWindow.make(contentRect: host.frame, contentView: host, key: true, placement: .transparentOnScreen)
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        func field() -> NSTextField? {
            var stack: [NSView] = [host]
            while let view = stack.popLast() {
                if let field = view as? NSTextField, field.isEditable { return field }
                stack += view.subviews
            }
            return nil
        }
        XCTAssertNil(field(), "平常是名字，不是输入框")

        renaming.start(a)
        var editable: NSTextField?
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            editable = field()
            if let editable, window.firstResponder === editable.currentEditor() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let input = try XCTUnwrap(editable, "换成了输入框")
        XCTAssertEqual(input.stringValue, "旧名字")
        XCTAssertTrue(window.firstResponder === input.currentEditor(), "已经拿到焦点，直接打字就是改名")
    }

}
