import UPaneGroups
import XCTest
@testable import uTerm

/// 本机终端窗口里的文件标签：⌘ 点的 Markdown 开在终端旁边，能改、自动保存、关前先存（同 SSH 终端窗口）。
/// 文件读写走注入的 `MockSFTP`（正式走辅助程序，见 `RemoteMacFileProvider.localShellAgent`），不起真 shell。
@MainActor
final class LocalShellFileTabTests: XCTestCase {
    private var mock: MockSFTP!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockSFTP()
        await mock.setFile("/Users/me/repo/plan.md", data: Data("# Plan".utf8), mtime: Date(timeIntervalSince1970: 1_000))
        await mock.setFile("/Users/me/repo/next.md", data: Data("# Next".utf8), mtime: Date(timeIntervalSince1970: 1_000))
    }

    private func makeModel() -> LocalShellWindowModel {
        let mock = mock!
        let model = LocalShellWindowModel(fileProvider: { mock }, startShell: { _ in })
        model.filePreviewModel.isAutosaveEnabled = { true }
        return model
    }

    private func fileTabs(_ model: LocalShellWindowModel) -> [UPaneTab<LocalShellPane>] {
        model.groups.allTabs.filter { $0.payload.fileBuffer != nil }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !condition() {
            if Date() > deadline { return XCTFail("等不到：\(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testOpensBesideTheTerminalAndKeepsFocusOnIt() async throws {
        let model = makeModel()
        let shell = model.addTab()

        await model.openFile("/Users/me/repo/plan.md", besidePane: shell)

        XCTAssertEqual(model.groups.groupCount, 2, "只有一组时往右分出一组")
        let file = try XCTUnwrap(fileTabs(model).first)
        XCTAssertTrue(file.isTransient, "临时标签，下一个会顶替它")
        XCTAssertEqual(file.payload.fileBuffer?.text, "# Plan")
        XCTAssertNotEqual(model.groups.locateTab(file.id)?.groupID, model.groups.locateTab(shell)?.groupID)
        XCTAssertEqual(model.active?.id, shell, "焦点留在发起的终端上")
        XCTAssertEqual(model.focusedSessionID, shell)

        await model.openFile("/Users/me/repo/next.md", besidePane: shell)
        XCTAssertEqual(model.groups.groupCount, 2, "已经有别的组就放进去，不再分")
        XCTAssertEqual(fileTabs(model).map { $0.payload.fileBuffer?.remotePath }, ["/Users/me/repo/next.md"], "顶替上一个")
    }

    func testFileTabsAreNotShellsAndStayOutOfTheHeldLayout() async throws {
        let model = makeModel()
        let shell = model.addTab()
        await model.openFile("/Users/me/repo/plan.md", besidePane: shell)
        let file = try XCTUnwrap(fileTabs(model).first)

        XCTAssertFalse(file.payload.isTerminal)
        XCTAssertEqual(model.panes.map(\.id), [shell], "文件标签不算 shell")
        XCTAssertNil(LocalShellWindowModel.layoutTabID(file), "不写进保持进程的布局")
        XCTAssertNil(LocalShellWindowModel.heldSessionID(file), "手机远控的标签顺序里没有它")
        XCTAssertEqual(file.payload.defaultTitle, "plan.md")
        let at = try XCTUnwrap(model.groups.locateTab(file.id))
        model.groups.activateTab(groupID: at.groupID, index: at.index)
        XCTAssertNil(model.focusedSessionID, "前台是文件标签时没有聚焦的会话")
    }

    func testDirectoriesAndMissingPathsDoNotOpen() async throws {
        let model = makeModel()
        let shell = model.addTab()
        await model.openFile("/Users/me/repo/missing.md", besidePane: shell)
        await model.openFile("/Users/me/repo", besidePane: shell)
        XCTAssertTrue(fileTabs(model).isEmpty)
        XCTAssertEqual(model.groups.groupCount, 1)
    }

    func testOpeningAnOpenFileAgainReloadsIt() async throws {
        let model = makeModel()
        let shell = model.addTab()
        await model.openFile("/Users/me/repo/plan.md", besidePane: shell)
        try await mock.write("/Users/me/repo/plan.md", data: Data("# Plan v2".utf8))
        await model.openFile("/Users/me/repo/plan.md", besidePane: shell)
        XCTAssertEqual(fileTabs(model).count, 1)
        XCTAssertEqual(fileTabs(model).first?.payload.fileBuffer?.text, "# Plan v2", "程序刚改过：重读")
    }

    func testEditsAutosaveToTheFile() async throws {
        let model = makeModel()
        model.filePreviewModel.autosaveDelay = .milliseconds(40)
        let shell = model.addTab()
        await model.openFile("/Users/me/repo/plan.md", besidePane: shell)
        let buffer = try XCTUnwrap(fileTabs(model).first?.payload.fileBuffer)

        buffer.applyEdit("# Plan edited")

        try await waitUntil("自动保存写回") {
            String(decoding: try await self.mock.read("/Users/me/repo/plan.md"), as: UTF8.self) == "# Plan edited"
        }
    }

    func testClosingAFileTabSavesFirstAndReleasesTheDocument() async throws {
        let model = makeModel()
        model.filePreviewModel.autosaveDelay = .seconds(60)   // 还没到点，关标签时要自己先存
        let shell = model.addTab()
        await model.openFile("/Users/me/repo/plan.md", besidePane: shell)
        let file = try XCTUnwrap(fileTabs(model).first)
        let buffer = try XCTUnwrap(file.payload.fileBuffer)

        buffer.applyEdit("# Plan v3")
        model.requestClose(file.id)

        try await waitUntil("存完并关掉") { model.groups.tab(file.id) == nil }
        let written = String(decoding: try await mock.read("/Users/me/repo/plan.md"), as: UTF8.self)
        XCTAssertEqual(written, "# Plan v3")
        XCTAssertFalse(model.filePreviewModel.owns(buffer.id), "关掉后文档也释放了")
        XCTAssertNotNil(model.groups.tab(shell), "终端不受影响")
    }

    func testShellTabsRouteFilePreviewRequestsBesideThemselves() async throws {
        let model = makeModel()
        let shell = model.addTab()
        let session = try XCTUnwrap(model.groups.tab(shell)?.payload.session)
        let handler = try XCTUnwrap(session.onFilePreviewRequest, "shell 标签接好了打开文件的入口")

        handler("/Users/me/repo/plan.md")

        try await waitUntil("开在旁边") { !self.fileTabs(model).isEmpty }
        XCTAssertEqual(model.active?.id, shell)
    }
}
