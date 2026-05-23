import XCTest
@testable import uTerm

@MainActor
final class FilePreviewModelTests: XCTestCase {

    private func makeModel() -> (FilePreviewModel, MockSFTP) {
        let mock = MockSFTP()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uTermTests-\(UUID().uuidString)")
        let store = RecentFilesStore(rootDirectory: tmp, fileName: "r.json")
        let m = FilePreviewModel(recentsStore: store, sftpProvider: { mock })
        return (m, mock)
    }

    func test_openSamePathTwice_doesNotDuplicate() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("hi".utf8))
        await m.open(path: "/x.swift", fileSize: 2, mtime: nil)
        await m.open(path: "/x.swift", fileSize: 2, mtime: nil)
        XCTAssertEqual(m.buffers.count, 1)
    }

    func test_openLoadsContent() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("let x = 1".utf8))
        await m.open(path: "/x.swift", fileSize: 9, mtime: nil)
        XCTAssertEqual(m.buffers.first?.text, "let x = 1")
        XCTAssertEqual(m.buffers.first?.state, .loaded)
        XCTAssertFalse(m.buffers.first?.isDirty ?? true)
    }

    func test_save_writesToSFTPAndClearsDirty() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("a".utf8))
        await m.open(path: "/x.swift", fileSize: 1, mtime: nil)
        let buf = m.buffers.first!
        buf.text = "b"; buf.isDirty = true
        let result = await m.save(buf.id)
        if case .saved = result {} else { return XCTFail("expected .saved, got \(result)") }
        XCTAssertFalse(buf.isDirty)
        let onRemote = try await mock.read("/x.swift")
        XCTAssertEqual(String(decoding: onRemote, as: UTF8.self), "b")
    }

    func test_save_detectsConflict_whenRemoteMtimeAdvanced() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("a".utf8))
        await m.open(path: "/x.swift", fileSize: 1, mtime: nil)
        let buf = m.buffers.first!
        buf.text = "b"; buf.isDirty = true
        // 外部修改远程：mtime 推后
        try await Task.sleep(for: .milliseconds(20))
        try await mock.write("/x.swift", data: Data("X".utf8))
        let result = await m.save(buf.id)
        if case .conflict = result { /* ok */ } else { return XCTFail("expected .conflict") }
    }

    func test_close_removesBuffer() async throws {
        let (m, mock) = makeModel()
        try await mock.write("/x.swift", data: Data("a".utf8))
        await m.open(path: "/x.swift", fileSize: 1, mtime: nil)
        let id = m.buffers.first!.id
        m.close(id, savingIfDirty: false)
        XCTAssertTrue(m.buffers.isEmpty)
        XCTAssertNil(m.activeBufferID)
    }
}
