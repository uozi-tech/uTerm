import XCTest
@testable import uTerm

/// 编辑远程文件后的自动保存（`FilePreviewModel.scheduleAutosave`）：停顿后写回、连续改合成一次、远端被别处改过不覆盖、
/// 写失败留在编辑器里、保存途中接着打字不丢字，以及关标签前先存。只用内存里的假 SFTP。
@MainActor
final class FileAutosaveTests: XCTestCase {

    private func makeModel(enabled: Bool = true) -> (FilePreviewModel, MockSFTP) {
        let mock = MockSFTP()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uTermTests-\(UUID().uuidString)")
        let store = RecentFilesStore(rootDirectory: tmp, fileName: "r.json")
        let m = FilePreviewModel(recentsStore: store, sftpProvider: { mock })
        m.isAutosaveEnabled = { enabled }
        m.autosaveDelay = .milliseconds(40)
        return (m, mock)
    }

    private func open(_ m: FilePreviewModel, _ mock: MockSFTP, _ path: String = "/x.md",
                      text: String = "a") async throws -> FileBuffer {
        await mock.setFile(path, data: Data(text.utf8), mtime: Date(timeIntervalSince1970: 1_000))
        await m.open(path: path, fileSize: nil, mtime: nil)
        return try XCTUnwrap(m.buffers.first { $0.remotePath == path })
    }

    private func remote(_ mock: MockSFTP, _ path: String = "/x.md") async throws -> String {
        String(decoding: try await mock.read(path), as: UTF8.self)
    }

    private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("一直没等到：\(what)")
    }

    func testEditIsWrittenBackAfterAPause() async throws {
        let (m, mock) = makeModel()
        let buf = try await open(m, mock)

        buf.applyEdit("b")
        XCTAssertTrue(buf.isDirty)
        try await waitUntil("存完") { !buf.isDirty }

        let written = try await remote(mock)
        XCTAssertEqual(written, "b")
        XCTAssertNil(buf.autosaveIssue)
        XCTAssertEqual(buf.state, .loaded)
    }

    func testRapidEditsBecomeOneWrite() async throws {
        let (m, mock) = makeModel()
        let buf = try await open(m, mock)

        buf.applyEdit("b")
        buf.applyEdit("bc")
        buf.applyEdit("bcd")
        try await waitUntil("存完") { !buf.isDirty }
        try await Task.sleep(for: .milliseconds(100))

        let writes = await mock.wholeWriteCount
        XCTAssertEqual(writes, 1, "停顿之后才写，连续的改动合成一次")
        let written = try await remote(mock)
        XCTAssertEqual(written, "bcd")
    }

    func testNothingIsWrittenWhenTurnedOff() async throws {
        let (m, mock) = makeModel(enabled: false)
        let buf = try await open(m, mock)

        buf.applyEdit("b")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(buf.isDirty)
        let writes = await mock.wholeWriteCount
        XCTAssertEqual(writes, 0)
    }

    func testRemoteChangeIsNotOverwrittenAndPausesAutosave() async throws {
        let (m, mock) = makeModel()
        let buf = try await open(m, mock)
        // 别处（终端里的 Claude）改了这个文件。
        await mock.setFile("/x.md", data: Data("theirs".utf8), mtime: Date(timeIntervalSince1970: 2_000))

        buf.applyEdit("mine")
        try await waitUntil("发现冲突") { buf.autosaveIssue == .conflict }

        var written = try await remote(mock)
        XCTAssertEqual(written, "theirs", "不自动覆盖")
        XCTAssertTrue(buf.isDirty)
        XCTAssertEqual(buf.state, .loaded)

        buf.applyEdit("mine 2")
        try await Task.sleep(for: .milliseconds(200))
        let writes = await mock.wholeWriteCount
        XCTAssertEqual(writes, 0, "冲突之后等用户决定，不再自动存")

        // 用户选「放弃本地改动」。
        await m.reloadFromRemote(buf.id)
        XCTAssertNil(buf.autosaveIssue)
        XCTAssertEqual(buf.text, "theirs")
        buf.applyEdit("theirs + mine")
        try await waitUntil("又能自动存") { !buf.isDirty }
        written = try await remote(mock)
        XCTAssertEqual(written, "theirs + mine")
    }

    func testFailedWriteStaysInTheEditorAndRetriesOnTheNextEdit() async throws {
        let (m, mock) = makeModel()
        let buf = try await open(m, mock)
        await mock.setWholeWriteError(NSError(domain: "test", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: "连接断了"]))

        buf.applyEdit("b")
        try await waitUntil("报失败") { buf.autosaveIssue != nil }
        XCTAssertEqual(buf.autosaveIssue, .failed("连接断了"))
        XCTAssertEqual(buf.state, .loaded, "内容还在编辑器里，不换成失败页")
        XCTAssertTrue(buf.isDirty)

        await mock.setWholeWriteError(nil)
        buf.applyEdit("bc")
        try await waitUntil("重试成功") { !buf.isDirty }
        XCTAssertNil(buf.autosaveIssue)
        let written = try await remote(mock)
        XCTAssertEqual(written, "bc")
    }

    func testTypingDuringASaveIsNotMarkedSaved() async throws {
        let (m, mock) = makeModel()
        let buf = try await open(m, mock)
        await mock.setHoldsWholeWrites(true)

        buf.applyEdit("b")
        try await waitUntil("写到一半") { await mock.heldWholeWriteCount == 1 }
        buf.applyEdit("bc")
        await mock.releaseWholeWrites()

        try await waitUntil("两次都写完") { !buf.isDirty }
        let written = try await remote(mock)
        XCTAssertEqual(written, "bc", "写的途中打的字也存上了")
        let writes = await mock.wholeWriteCount
        XCTAssertEqual(writes, 2)
    }

    func testDetachedDocumentWritesThroughItsOwnHost() async throws {
        let (m, sidebar) = makeModel()
        let other = MockSFTP()
        await other.setFile("/srv/plan.md", data: Data("# Plan".utf8), mtime: Date(timeIntervalSince1970: 1_000))
        let buf = await m.openDetached(path: "/srv/plan.md", provider: other)

        buf.applyEdit("# Plan v2")
        try await waitUntil("存完") { !buf.isDirty }

        let written = String(decoding: try await other.read("/srv/plan.md"), as: UTF8.self)
        XCTAssertEqual(written, "# Plan v2")
        let sidebarWrites = await sidebar.wholeWriteCount
        XCTAssertEqual(sidebarWrites, 0)
    }

    func testReleasedDocumentIsNotWrittenAfterClosing() async throws {
        let (m, mock) = makeModel()
        let buf = try await open(m, mock)

        buf.applyEdit("b")
        XCTAssertTrue(m.closeTab(try XCTUnwrap(m.panes.allTabs.first?.id)))
        try await Task.sleep(for: .milliseconds(200))

        let writes = await mock.wholeWriteCount
        XCTAssertEqual(writes, 0, "「不保存」关掉的文档，排着的自动保存不再写")
    }

    func testClosingADirtyTabSavesFirst() async throws {
        let (m, mock) = makeModel()
        m.autosaveDelay = .seconds(60)   // 还没到点，关标签时要自己先存
        let buf = try await open(m, mock)
        buf.applyEdit("b")

        let closed = expectation(description: "存完才关")
        m.closeAfterSaving(buf) {
            XCTAssertFalse(buf.isDirty)
            closed.fulfill()
        }
        await fulfillment(of: [closed], timeout: 3)
        let written = try await remote(mock)
        XCTAssertEqual(written, "b")
    }

    func testTerminalAreaFileTabSavesBeforeClosing() async throws {
        let workspace = WorkspaceModel()
        let mock = MockSFTP()
        workspace.makeFileProvider = { _ in mock }
        workspace.filePreviewModel.isAutosaveEnabled = { true }
        workspace.filePreviewModel.autosaveDelay = .seconds(60)
        let serverID = UUID()
        let terminalTab = workspace.openServer(profileID: serverID, title: "uozi-sz")
        let paneID = try XCTUnwrap(workspace.terminalGroups.tab(terminalTab)?.payload.id)
        await mock.setFile("/srv/plan.md", data: Data("# Plan".utf8), mtime: Date(timeIntervalSince1970: 1_000))
        await workspace.openInTerminalArea("/srv/plan.md", serverID: serverID, besidePane: paneID)
        let fileTab = try XCTUnwrap(workspace.terminalGroups.allTabs.first { $0.payload.fileBuffer != nil })
        let buf = try XCTUnwrap(fileTab.payload.fileBuffer)

        buf.applyEdit("# Plan v2")
        workspace.requestCloseTerminalTab(fileTab.id)

        try await waitUntil("存完并关掉") {
            !workspace.terminalGroups.allTabs.contains { $0.id == fileTab.id }
        }
        let written = String(decoding: try await mock.read("/srv/plan.md"), as: UTF8.self)
        XCTAssertEqual(written, "# Plan v2")
        XCTAssertFalse(workspace.filePreviewModel.owns(buf.id), "关掉后文档也释放了")
    }

    func testPreferenceDefaultsToOn() {
        let defaults = UserDefaults(suiteName: "uTermTests-autosave-\(UUID().uuidString)")!
        XCTAssertTrue(FilePreviewModel.autosavePreference(defaults))
        defaults.set(false, forKey: DefaultsKey.editorAutoSave)
        XCTAssertFalse(FilePreviewModel.autosavePreference(defaults))
    }
}
