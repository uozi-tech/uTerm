import XCTest
@testable import uTerm

final class WorkspaceStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func sampleSnapshot(title: String) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            tabs: [TabSnapshot(title: title, layout: .leaf(serverProfileID: UUID()))],
            activeTabIndex: 0)
    }

    func testSaveThenLoadRoundTrip() throws {
        let dir = tempDir()
        let windowID = WorkspaceWindowID(id: UUID(), serverID: UUID())
        let store = WorkspaceStore(windowID: windowID, directory: dir)
        let snap = sampleSnapshot(title: "win-a")
        try store.save(snap)
        XCTAssertEqual(store.load(), snap)
    }

    func testTwoWindowsAreIsolated() throws {
        let dir = tempDir()
        let a = WorkspaceWindowID(id: UUID(), serverID: UUID())
        let b = WorkspaceWindowID(id: UUID(), serverID: UUID())
        let snapA = sampleSnapshot(title: "a")
        try WorkspaceStore(windowID: a, directory: dir).save(snapA)
        XCTAssertNil(WorkspaceStore(windowID: b, directory: dir).load())
        XCTAssertEqual(WorkspaceStore(windowID: a, directory: dir).load(), snapA)
    }

    func testFileNameIsPerWindow() throws {
        let dir = tempDir()
        let windowID = WorkspaceWindowID(id: UUID(), serverID: UUID())
        try WorkspaceStore(windowID: windowID, directory: dir).save(sampleSnapshot(title: "t"))
        let expected = dir.appendingPathComponent("workspace-\(windowID.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testLoadMissingReturnsNil() {
        let windowID = WorkspaceWindowID(id: UUID(), serverID: UUID())
        XCTAssertNil(WorkspaceStore(windowID: windowID, directory: tempDir()).load())
    }

    func testLoadCorruptReturnsNil() throws {
        let dir = tempDir()
        let windowID = WorkspaceWindowID(id: UUID(), serverID: UUID())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: dir.appendingPathComponent("workspace-\(windowID.id.uuidString).json"))
        XCTAssertNil(WorkspaceStore(windowID: windowID, directory: dir).load())
    }

    func testPurgeLegacyWorkspaceFileRemovesIt() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("workspace.json")
        try Data("{}".utf8).write(to: legacy)
        WorkspaceStore.purgeLegacyWorkspaceFile(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testPurgeLegacyWorkspaceFileNoThrowWhenAbsent() {
        WorkspaceStore.purgeLegacyWorkspaceFile(directory: tempDir())   // 不存在时不应崩溃
    }
}
