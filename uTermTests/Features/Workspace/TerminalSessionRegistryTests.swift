import XCTest
@testable import uTerm

@MainActor
final class TerminalSessionRegistryTests: XCTestCase {

    private func makeEntry(
        id: UUID = UUID(),
        serverID: UUID = UUID(),
        serverName: String = "prod-web",
        windowID: UUID = UUID(),
        windowKind: String = TerminalWindowKind.workspace,
        title: String? = nil
    ) -> TerminalSessionEntry {
        TerminalSessionEntry(
            id: id,
            serverID: serverID,
            serverName: serverName,
            windowID: windowID,
            windowKind: windowKind,
            title: title ?? serverName,
            connectedAt: Date()
        )
    }

    // MARK: 注册 / 注销 / 更新

    func testRegisterAppendsInOrder() {
        let registry = TerminalSessionRegistry()
        let a = makeEntry(serverName: "a")
        let b = makeEntry(serverName: "b")
        registry.register(a)
        registry.register(b)
        XCTAssertEqual(registry.entries.map(\.id), [a.id, b.id])
    }

    /// 同 id 重复登记是**更新**，且保留原插入位置（否则切换服务器会让会话在
    /// `terminals` 里跳到末尾）。
    func testRegisterSameIDUpdatesInPlace() {
        let registry = TerminalSessionRegistry()
        let first = makeEntry(serverName: "a")
        let other = makeEntry(serverName: "b")
        registry.register(first)
        registry.register(other)
        registry.register(makeEntry(id: first.id, serverName: "a2"))
        XCTAssertEqual(registry.entries.count, 2)
        XCTAssertEqual(registry.entries[0].serverName, "a2")
        XCTAssertEqual(registry.entries[1].id, other.id)
    }

    func testUnregisterRemovesEntryAndSession() {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let entry = makeEntry()
        registry.register(entry, session: session)
        XCTAssertNotNil(registry.session(for: entry.id))
        registry.unregister(id: entry.id)
        XCTAssertTrue(registry.entries.isEmpty)
        XCTAssertNil(registry.session(for: entry.id))
    }

    func testUpdateTitle() {
        let registry = TerminalSessionRegistry()
        let entry = makeEntry(title: "旧")
        registry.register(entry)
        registry.update(id: entry.id, title: "新")
        XCTAssertEqual(registry.entries[0].title, "新")
        // 不存在的 id 是 no-op，不是崩。
        registry.update(id: UUID(), title: "无关")
        XCTAssertEqual(registry.entries.count, 1)
    }

    /// 注册表**绝不延长会话寿命**：会话释放后槽位读出 nil。
    func testSessionIsHeldWeakly() {
        let registry = TerminalSessionRegistry()
        let entry = makeEntry()
        do {
            let session = TerminalSession()
            registry.register(entry, session: session)
            XCTAssertNotNil(registry.session(for: entry.id))
        }
        XCTAssertNil(registry.session(for: entry.id))
        // entry 本身还在（`terminals` 仍会列出来，read 时才报 terminal_disconnected）。
        XCTAssertEqual(registry.entries.count, 1)
    }

    // MARK: key window / 焦点

    func testIsKeyWindowFocusedNeedsBothKeyWindowAndActiveTab() {
        let registry = TerminalSessionRegistry()
        let window = UUID()
        let a = makeEntry(serverName: "a", windowID: window)
        let b = makeEntry(serverName: "b", windowID: window)
        registry.register(a)
        registry.register(b)
        XCTAssertFalse(registry.entries.contains { $0.isKeyWindowFocused })

        // 只有 key window，没设活动标签 → 仍不算聚焦。
        registry.setKeyWindow(windowID: window, isKey: true)
        XCTAssertFalse(registry.entries.contains { $0.isKeyWindowFocused })

        registry.setFocusedSession(a.id, inWindow: window)
        XCTAssertTrue(registry.entries.first { $0.id == a.id }!.isKeyWindowFocused)
        XCTAssertFalse(registry.entries.first { $0.id == b.id }!.isKeyWindowFocused)

        // 切标签。
        registry.setFocusedSession(b.id, inWindow: window)
        XCTAssertFalse(registry.entries.first { $0.id == a.id }!.isKeyWindowFocused)
        XCTAssertTrue(registry.entries.first { $0.id == b.id }!.isKeyWindowFocused)

        // 窗口失去 key。
        registry.setKeyWindow(windowID: window, isKey: false)
        XCTAssertFalse(registry.entries.contains { $0.isKeyWindowFocused })
    }

    func testFocusIsPerWindow() {
        let registry = TerminalSessionRegistry()
        let w1 = UUID(), w2 = UUID()
        let a = makeEntry(windowID: w1)
        let b = makeEntry(windowID: w2)
        registry.register(a)
        registry.register(b)
        registry.setKeyWindow(windowID: w1, isKey: true)
        registry.setFocusedSession(a.id, inWindow: w1)
        registry.setFocusedSession(b.id, inWindow: w2)  // w2 不是 key
        XCTAssertTrue(registry.entries.first { $0.id == a.id }!.isKeyWindowFocused)
        XCTAssertFalse(registry.entries.first { $0.id == b.id }!.isKeyWindowFocused)
    }

    func testForgetWindowClearsFocusFlag() {
        let registry = TerminalSessionRegistry()
        let window = UUID()
        let entry = makeEntry(windowID: window)
        registry.register(entry)
        registry.setKeyWindow(windowID: window, isKey: true)
        registry.setFocusedSession(entry.id, inWindow: window)
        XCTAssertTrue(registry.entries[0].isKeyWindowFocused)
        registry.forgetWindow(window)
        XCTAssertFalse(registry.entries[0].isKeyWindowFocused)
    }

    // MARK: 解析

    func testResolveByFullID() throws {
        let registry = TerminalSessionRegistry()
        let entry = makeEntry()
        registry.register(entry)
        XCTAssertEqual(try registry.resolve(entry.id.uuidString).id, entry.id)
        // UUID 大小写不敏感。
        XCTAssertEqual(try registry.resolve(entry.id.uuidString.lowercased()).id, entry.id)
    }

    func testResolveByUniquePrefix() throws {
        let registry = TerminalSessionRegistry()
        let entry = makeEntry(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
        registry.register(entry)
        registry.register(makeEntry(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!))
        XCTAssertEqual(try registry.resolve("AAAA").id, entry.id)
        // 前缀也不区分大小写。
        XCTAssertEqual(try registry.resolve("aaaa").id, entry.id)
    }

    func testResolveAmbiguousPrefixThrows() {
        let registry = TerminalSessionRegistry()
        registry.register(makeEntry(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!))
        registry.register(makeEntry(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!))
        XCTAssertThrowsError(try registry.resolve("AAAAAAAA")) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, .terminal_ambiguous)
        }
    }

    func testResolveMissingThrowsNotFound() {
        let registry = TerminalSessionRegistry()
        registry.register(makeEntry())
        XCTAssertThrowsError(try registry.resolve("ZZZZ")) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, .terminal_not_found)
        }
        XCTAssertThrowsError(try registry.resolve("   ")) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, .terminal_not_found)
        }
    }

    // MARK: 线上形状

    func testSnapshotMapsToWireShape() {
        let registry = TerminalSessionRegistry()
        let entry = makeEntry(windowKind: TerminalWindowKind.terminal, title: "web-1")
        registry.register(entry)
        let snapshot = registry.snapshots()[0]
        XCTAssertEqual(snapshot.id, entry.id.uuidString)
        XCTAssertEqual(snapshot.serverID, entry.serverID.uuidString)
        XCTAssertEqual(snapshot.serverName, entry.serverName)
        XCTAssertEqual(snapshot.windowKind, "terminal")
        XCTAssertEqual(snapshot.title, "web-1")
        XCTAssertFalse(snapshot.isKeyWindowFocused)
        XCTAssertNotNil(snapshot.connectedAt)
    }

    // MARK: terminal-open 的等待

    func testWaitForSessionReturnsWhenRegistered() async {
        let registry = TerminalSessionRegistry()
        let window = UUID()
        let entry = makeEntry(windowID: window)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            registry.register(entry)
        }
        let hit = await registry.waitForSession(inWindow: window, timeout: .seconds(3))
        XCTAssertEqual(hit?.id, entry.id)
    }

    func testWaitForSessionTimesOut() async {
        let registry = TerminalSessionRegistry()
        let hit = await registry.waitForSession(
            inWindow: UUID(), timeout: .milliseconds(150), pollInterval: .milliseconds(30))
        XCTAssertNil(hit)
    }

    // MARK: 窗格接线（PaneModel ↔ 注册表）

    func testPaneRegistrarUnregistersOnDispose() {
        let registry = TerminalSessionRegistry()
        let pane = PaneModel(serverProfileID: UUID())
        let registrar = TerminalSessionRegistrar(
            registry: registry, windowID: UUID(), windowKind: TerminalWindowKind.workspace)
        pane.registrar = registrar
        registrar.register(paneID: pane.id, serverID: pane.serverProfileID,
                           serverName: "prod", session: pane.session)
        XCTAssertEqual(registry.entries.count, 1)
        pane.dispose()
        XCTAssertTrue(registry.entries.isEmpty)
    }

    /// 文件窗格不是终端会话，`adopt` 不该把它登记进去。
    func testFilePaneIsNotAdopted() {
        let registry = TerminalSessionRegistry()
        let pane = PaneModel(serverProfileID: UUID(),
                             fileBuffer: FileBuffer(remotePath: "/tmp/a.md", kind: .markdown))
        pane.adopt(registrar: TerminalSessionRegistrar(
            registry: registry, windowID: UUID(), windowKind: TerminalWindowKind.workspace))
        XCTAssertNil(pane.registrar)
        XCTAssertTrue(registry.entries.isEmpty)
    }
}
